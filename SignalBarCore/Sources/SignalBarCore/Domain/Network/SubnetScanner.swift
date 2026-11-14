import Darwin
import Foundation
import SystemConfiguration

/// Where a piece of network information came from. Stored with everything
/// the app records about a device, so the UI can always say how it knows.
public enum NetworkObservationSource: String, Sendable, Codable, CaseIterable {
    /// This Mac's ARP cache after a sweep: the device answered on the link.
    case arpLocal = "arp_local"
    case icmp
    /// A TCP handshake or reset: something is at that address.
    case tcp
    /// A router's ARP table, read over SNMP.
    case arpSNMP = "arp_snmp"
    /// A switch's MAC address table, read over SNMP.
    case fdbSNMP = "fdb_snmp"
    case dhcp
    case mdns
    case reverseDNS = "rdns"
    case manual
    /// The Mac running SignalBar.
    case thisMac = "this_mac"

    /// Whether a sighting from this source means the device is on the
    /// network now. A DHCP lease only says an address was handed out, and a
    /// name lookup only that a record exists.
    public var provesPresence: Bool {
        switch self {
        case .arpLocal, .icmp, .tcp, .arpSNMP, .fdbSNMP, .thisMac: true
        case .dhcp, .mdns, .reverseDNS, .manual: false
        }
    }

    /// How much a hostname from this source is trusted over another one.
    var hostnameRank: Int {
        switch self {
        case .manual: 5
        case .thisMac: 4
        case .dhcp: 3
        case .mdns: 2
        case .reverseDNS: 1
        default: 0
        }
    }
}

/// One thing a scan or a poll saw at one address.
public struct HostObservation: Sendable, Equatable {
    public var ip: IPv4Address
    public var mac: MACAddress?
    public var source: NetworkObservationSource
    /// The SNMP or DHCP source it came from, if any.
    public var sourceID: Int64?
    public var hostname: String?
    public var hostnameSource: NetworkObservationSource?
    public var vlanID: Int?
    /// The switch interface the MAC was learned on, as the switch names it.
    public var switchPort: String?
    public var latencyMs: Double?
    /// What the device evidently is (the default gateway is a router, this
    /// Mac a computer); only fills a type the user hasn't set.
    public var deviceType: NetworkDeviceType?

    public init(
        ip: IPv4Address, mac: MACAddress?, source: NetworkObservationSource, sourceID: Int64? = nil,
        hostname: String? = nil, hostnameSource: NetworkObservationSource? = nil,
        vlanID: Int? = nil, switchPort: String? = nil, latencyMs: Double? = nil, deviceType: NetworkDeviceType? = nil
    ) {
        self.ip = ip
        self.mac = mac
        self.source = source
        self.sourceID = sourceID
        self.hostname = hostname
        self.hostnameSource = hostname == nil ? nil : (hostnameSource ?? source)
        self.vlanID = vlanID
        self.switchPort = switchPort
        self.latencyMs = latencyMs
        self.deviceType = deviceType
    }
}

public enum SubnetScanMode: String, Sendable, Codable {
    /// The Mac has an address in the subnet: ARP, ping and mDNS all work.
    case direct
    /// Reached through a router: ping and TCP only, so addresses but no MACs.
    case routed
}

public enum SubnetScanProblem: String, Sendable, Codable {
    /// macOS's Local Network permission is off for SignalBar, so every
    /// packet to the LAN was refused. Nothing about the devices is known.
    case localNetworkDenied = "local_network_denied"
    /// No route from this Mac to the subnet at all.
    case noRoute = "no_route"
}

public struct SubnetScanOutcome: Sendable, Equatable {
    public var mode: SubnetScanMode
    public var observations: [HostObservation]
    public var probedCount: Int
    /// Set when the scan learned nothing about the devices; such a run must
    /// not count against them as "not seen".
    public var problem: SubnetScanProblem?

    public init(mode: SubnetScanMode, observations: [HostObservation], probedCount: Int, problem: SubnetScanProblem? = nil) {
        self.mode = mode
        self.observations = observations
        self.probedCount = probedCount
        self.problem = problem
    }
}

public protocol SubnetScanning: Sendable {
    func scan(_ subnet: IPv4CIDR, resolveNames: Bool) async -> SubnetScanOutcome
}

/// Scans one subnet from this Mac, without root and without raw packets.
public struct SubnetScanner: SubnetScanning {
    /// Ports tried on a routed host that doesn't answer ping: ones that are
    /// open, or at least answered with a reset, on most kinds of device.
    static let presencePorts: [UInt16] = [22, 80, 443, 445, 3389, 8080]

    public init() {}

    public func scan(_ subnet: IPv4CIDR, resolveNames: Bool) async -> SubnetScanOutcome {
        let interface = LocalNetworkContext.interfaces().first { $0.network.overlaps(subnet) }
        // Only the part of the subnet on the Mac's own link can be found by
        // ARP; any part of a wider subnet beyond it goes through the router.
        let onLink = subnet.hosts.filter { host in interface.map { $0.network.contains(host) && host != $0.address } ?? false }
        let offLink = subnet.hosts.filter { host in !(interface?.network.contains(host) ?? false) }

        var observations: [HostObservation] = []
        var problems: [SubnetScanProblem] = []
        if let interface, !onLink.isEmpty {
            let (found, problem) = await scanOnLink(onLink)
            observations += found
            problems += problem.map { [$0] } ?? []
            if problem == nil, subnet.contains(interface.address) {
                observations.append(HostObservation(
                    ip: interface.address, mac: interface.mac, source: .thisMac,
                    hostname: Self.localHostName(), hostnameSource: .thisMac, deviceType: .computer
                ))
            }
        }
        if !offLink.isEmpty, !Task.isCancelled {
            let (found, problem) = await scanRouted(offLink)
            observations += found
            problems += problem.map { [$0] } ?? []
        }

        if let gateway = LocalNetworkContext.defaultGateway(), let index = observations.firstIndex(where: { $0.ip == gateway }) {
            observations[index].deviceType = .router
        }

        let mode: SubnetScanMode = interface == nil ? .routed : .direct
        let probed = onLink.count + offLink.count
        // A problem only stands when nothing at all was learned; one part of
        // a wide subnet failing while the other answered is still a scan.
        if observations.isEmpty, let problem = problems.first {
            return SubnetScanOutcome(mode: mode, observations: [], probedCount: probed, problem: problem)
        }
        guard resolveNames, !Task.isCancelled else {
            return SubnetScanOutcome(mode: mode, observations: observations, probedCount: probed)
        }

        let unnamed = observations.filter { $0.hostname == nil }.map(\.ip)
        var names: [IPv4Address: (String, NetworkObservationSource)] = [:]
        if let interface {
            let local = unnamed.filter { interface.network.contains($0) }
            for (ip, name) in await NameLookup.multicastDNS(local, via: interface.address) { names[ip] = (name, .mdns) }
        }
        for (ip, name) in await NameLookup.reverseDNS(unnamed.filter { names[$0] == nil }) { names[ip] = (name, .reverseDNS) }
        for index in observations.indices {
            if let (name, source) = names[observations[index].ip] {
                observations[index].hostname = name
                observations[index].hostnameSource = source
            }
        }
        return SubnetScanOutcome(mode: mode, observations: observations, probedCount: probed)
    }

    private func scanOnLink(_ hosts: [IPv4Address]) async -> ([HostObservation], SubnetScanProblem?) {
        let sweep = await runBlocking { cancel in HostSweep.run(hosts, onLink: true, cancel: cancel) }
        if Self.looksDenied(sweep, hostCount: hosts.count) { return ([], .localNetworkDenied) }
        let present = sweep.answeredARP.union(sweep.echoReplies.keys)
        let observations = present.map { ip in
            HostObservation(ip: ip, mac: nil, source: sweep.answeredARP.contains(ip) ? .arpLocal : .icmp, latencyMs: sweep.echoReplies[ip])
        }
        return (observations, nil)
    }

    private func scanRouted(_ hosts: [IPv4Address]) async -> ([HostObservation], SubnetScanProblem?) {
        let sweep = await runBlocking { cancel in HostSweep.run(hosts, onLink: false, cancel: cancel) }
        if Self.looksDenied(sweep, hostCount: hosts.count) { return ([], .localNetworkDenied) }
        if sweep.echoReplies.isEmpty, sweep.firstPassErrors.count == hosts.count,
           sweep.firstPassErrors.values.allSatisfy({ $0 == ENETUNREACH }) {
            return ([], .noRoute)
        }

        let silent = hosts.filter { sweep.echoReplies[$0] == nil }
        let targets = silent.flatMap { host in Self.presencePorts.map { (host, $0) } }
        let probes = await runBlocking { cancel in
            TCPConnectProbe.run(targets, timeout: 1, maxInFlight: 64, cancel: cancel)
        }
        let present = Self.hostsPresent(from: probes, probedHostCount: silent.count)
        let observations = sweep.echoReplies.map { HostObservation(ip: $0.key, mac: nil, source: .icmp, latencyMs: $0.value) }
            + present.map { HostObservation(ip: $0.key, mac: nil, source: .tcp, latencyMs: $0.value) }
        return (observations, nil)
    }

    /// Addresses a TCP probe proved present, with the fastest answer.
    ///
    /// A reset counts as presence, except when nearly every address "answered"
    /// only with resets: that's a firewall rejecting on behalf of addresses
    /// that hold nothing, and believing it would fill the list with ghosts.
    static func hostsPresent(from probes: [TCPProbeResult], probedHostCount: Int) -> [IPv4Address: Double] {
        let answered = probes.filter { $0.state != .filtered }
        let byHost = Dictionary(grouping: answered, by: \.ip)
        let openHosts = Set(answered.filter { $0.state == .open }.map(\.ip))
        let resetOnly = byHost.count - openHosts.count
        let trustResets = probedHostCount < 8 || Double(resetOnly) < Double(probedHostCount) * 0.9
        var present: [IPv4Address: Double] = [:]
        for (host, results) in byHost where trustResets || openHosts.contains(host) {
            present[host] = results.compactMap(\.latencyMs).min()
        }
        return present
    }

    /// Every first send refused with "no route to host" or "not permitted"
    /// while nothing answered: what macOS does to an app denied Local Network
    /// access. A device marked down by an earlier scan is refused too, but
    /// never every address at once, the router included.
    static func looksDenied(_ sweep: SweepResult, hostCount: Int) -> Bool {
        guard hostCount > 0, sweep.echoReplies.isEmpty, sweep.firstPassErrors.count == hostCount else { return false }
        return sweep.firstPassErrors.values.allSatisfy { $0 == EHOSTUNREACH || $0 == EPERM || $0 == EACCES }
    }

    private static func localHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }
}
