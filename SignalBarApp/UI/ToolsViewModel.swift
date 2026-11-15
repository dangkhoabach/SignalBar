import Foundation
import Observation
import SignalBarCore

enum NetworkTool: String, CaseIterable, Identifiable {
    case ping, traceroute, dns, ports, whois, http, wake

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .ping: "Ping"
        case .traceroute: "Traceroute"
        case .dns: "DNS"
        case .ports: "Ports"
        case .whois: "Whois"
        case .http: "HTTP"
        case .wake: "Wake"
        }
    }
}

enum DNSServerChoice: String, CaseIterable, Identifiable {
    case system, cloudflare, google, quad9, custom

    var id: Self { self }

    var fixedAddress: String? {
        switch self {
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        case .quad9: "9.9.9.9"
        case .system, .custom: nil
        }
    }
}

/// Network › Tools. Each tool keeps its input and last result while the user
/// moves around the app; a ping or trace that is running keeps running.
@MainActor
@Observable
final class ToolsViewModel {
    static let shared = ToolsViewModel()

    var tool: NetworkTool = .ping

    // MARK: Ping

    static let pingCounts: [Int?] = [4, 10, 50, nil]
    var pingHost = ""
    var pingPreference: AddressPreference = .automatic
    var pingCount: Int? = 10
    private(set) var pingTarget: ToolAddress?
    private(set) var pingReplies: [PingReply] = []
    private(set) var pingError: String?
    private var pingTask: Task<Void, Never>?
    var isPinging: Bool { pingTask != nil }
    var pingStats: PingStatistics { PingStatistics(pingReplies) }

    func startPing() {
        stopPing()
        pingReplies = []
        pingError = nil
        pingTarget = nil
        let host = pingHost, preference = pingPreference, count = pingCount
        pingTask = Task {
            defer { pingTask = nil }
            do {
                let target = try await ToolTarget.resolve(host, preference: preference)
                pingTarget = target
                for await reply in Ping.run(target, options: PingOptions(count: count)) {
                    pingReplies.append(reply)
                    // A ping left running for hours keeps the last few thousand.
                    if pingReplies.count > 5_000 { pingReplies.removeFirst(pingReplies.count - 5_000) }
                }
            } catch {
                pingError = error.localizedDescription
            }
        }
    }

    func stopPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    // MARK: Traceroute

    var traceHost = ""
    var tracePreference: AddressPreference = .automatic
    /// Keep sending rounds until stopped, as mtr does.
    var traceContinuous = false
    private(set) var traceTarget: ToolAddress?
    private(set) var trace = TraceSummary()
    private(set) var traceError: String?
    private(set) var hopNames: [ToolAddress: String] = [:]
    private(set) var hopNetworks: [ToolAddress: String] = [:]
    private var traceTask: Task<Void, Never>?
    private var looked: Set<ToolAddress> = []
    var isTracing: Bool { traceTask != nil }

    func startTrace() {
        stopTrace()
        trace = TraceSummary()
        traceError = nil
        traceTarget = nil
        let host = traceHost, preference = tracePreference
        let options = TraceOptions(rounds: traceContinuous ? nil : 3)
        let lookupNetworks = Self.lookupsEnabled
        traceTask = Task {
            defer { traceTask = nil }
            do {
                let target = try await ToolTarget.resolve(host, preference: preference)
                traceTarget = target
                for await round in Traceroute.run(target, options: options) {
                    trace.add(round: round)
                    describeNewHops(lookupNetworks: lookupNetworks)
                }
            } catch {
                traceError = error.localizedDescription
            }
        }
    }

    func stopTrace() {
        traceTask?.cancel()
        traceTask = nil
    }

    /// The same switch as the Connection page's lookups: off, no hop address goes to RIPEstat.
    private static var lookupsEnabled: Bool {
        guard let database = AppDatabase.shared, let settings = try? SettingsRepository(dbQueue: database.dbQueue).load() else { return false }
        return settings.connectionPublicLookupEnabled
    }

    /// Names every new hop address once: its PTR name, and for a public
    /// address the network it belongs to (RIPEstat, when lookups are on).
    private func describeNewHops(lookupNetworks: Bool) {
        for address in trace.hops.flatMap(\.addresses) where looked.insert(address).inserted {
            Task {
                if let name = await PublicAddressLookup.reverseName(of: address.description) { hopNames[address] = name }
                guard lookupNetworks, !address.isInternal else { return }
                if let network = await PublicAddressLookup().network(of: address.description) {
                    hopNetworks[address] = "AS\(network.asn) \(network.holder)"
                }
            }
        }
    }

    // MARK: DNS

    struct DNSRun: Identifiable {
        var label: String
        var server: String
        var result: DNSLookupResult?
        var error: String?
        var id: String { server }
    }

    var dnsName = ""
    var dnsType: DNSQueryType = .a
    var dnsServer: DNSServerChoice = .system
    var dnsCustomServer = ""
    /// Ask the system's server and the three public ones side by side.
    var dnsCompare = false
    private(set) var dnsRuns: [DNSRun] = []
    private(set) var dnsQueryName: String?
    private(set) var isLookingUp = false

    /// The first DNS server this Mac uses that can be asked directly.
    var systemDNSServer: String? {
        SystemNetworkReader.read().dns.servers.first { !$0.lowercased().hasPrefix("fe80") && !$0.contains("%") }
    }

    func lookUp() {
        let (name, isReverse) = DNSLookup.queryName(for: dnsName)
        guard !name.isEmpty else { return }
        if isReverse { dnsType = .ptr }
        let type = dnsType
        var servers: [(String, String)] = []
        if dnsCompare {
            if let system = systemDNSServer { servers.append((AppLocale.string("System"), system)) }
            for choice in [DNSServerChoice.cloudflare, .google, .quad9] {
                if let address = choice.fixedAddress, !servers.contains(where: { $0.1 == address }) { servers.append((Self.label(choice), address)) }
            }
        } else if dnsServer == .custom {
            servers = [(dnsCustomServer, dnsCustomServer.trimmingCharacters(in: .whitespaces))]
        } else if dnsServer == .system {
            servers = systemDNSServer.map { [(AppLocale.string("System"), $0)] } ?? []
        } else if let address = dnsServer.fixedAddress {
            servers = [(Self.label(dnsServer), address)]
        }
        dnsQueryName = name
        dnsRuns = servers.map { DNSRun(label: $0.0, server: $0.1) }
        guard !servers.isEmpty else { return }
        isLookingUp = true
        Task {
            await withTaskGroup(of: (String, DNSLookupResult?, String?).self) { group in
                for (_, server) in servers {
                    group.addTask {
                        do { return (server, try await DNSLookup.query(name, type: type, server: server), nil) }
                        catch { return (server, nil, error.localizedDescription) }
                    }
                }
                for await (server, result, error) in group {
                    if let index = dnsRuns.firstIndex(where: { $0.server == server }) {
                        dnsRuns[index].result = result
                        dnsRuns[index].error = error
                    }
                }
            }
            isLookingUp = false
        }
    }

    static func label(_ choice: DNSServerChoice) -> String {
        switch choice {
        case .system: AppLocale.string("System")
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .quad9: "Quad9"
        case .custom: AppLocale.string("Custom")
        }
    }

    // MARK: Ports

    var portHost = ""
    var portsText = NetworkMonitor.commonPorts.map(String.init).joined(separator: ", ")
    var showsOnlyOpenPorts = false
    private(set) var portTarget: ToolAddress?
    private(set) var portResults: [PortCheckResult] = []
    private(set) var portsTotal = 0
    private(set) var portError: String?
    private var portTask: Task<Void, Never>?
    var isCheckingPorts: Bool { portTask != nil }

    func checkPorts() {
        stopPorts()
        let ports = PortCheck.parse(portsText)
        portResults = []
        portError = ports.isEmpty ? AppLocale.string("Enter ports such as 22, 80, 443 or a range such as 8000-8100.") : nil
        portTarget = nil
        portsTotal = ports.count
        guard !ports.isEmpty else { return }
        let host = portHost
        portTask = Task {
            defer { portTask = nil }
            do {
                let target = try await ToolTarget.resolve(host)
                portTarget = target
                for await result in PortCheck.run(target, ports: ports) {
                    portResults.append(result)
                }
                portResults.sort { $0.port < $1.port }
            } catch {
                portError = error.localizedDescription
            }
        }
    }

    func stopPorts() {
        portTask?.cancel()
        portTask = nil
    }

    // MARK: Whois

    var whoisQuery = ""
    private(set) var whoisOutput: String?
    private(set) var whoisError: String?
    private(set) var isQueryingWhois = false

    func runWhois() {
        let query = whoisQuery
        whoisOutput = nil
        whoisError = nil
        isQueryingWhois = true
        Task {
            do { whoisOutput = try await Whois.lookup(query) } catch { whoisError = error.localizedDescription }
            isQueryingWhois = false
        }
    }

    // MARK: HTTP

    var httpURL = ""
    var followRedirects = true
    private(set) var httpResult: HTTPCheckResult?
    private(set) var httpError: String?
    private(set) var isCheckingHTTP = false

    func runHTTPCheck() {
        let text = httpURL, follow = followRedirects
        httpResult = nil
        httpError = nil
        isCheckingHTTP = true
        Task {
            do { httpResult = try await HTTPCheck.run(text, followRedirects: follow) } catch { httpError = error.localizedDescription }
            isCheckingHTTP = false
        }
    }

    // MARK: Wake-on-LAN

    var wakeMAC = ""
    private(set) var wakeMessage: String?
    private(set) var wakeFailed = false

    /// Where the magic packet goes: the broadcast address of the subnet the
    /// device is known in (or this Mac's own), and the local broadcast.
    func wakeBroadcasts(for mac: MACAddress) -> [IPv4Address] {
        var broadcasts: [IPv4Address] = []
        let network = NetworkViewModel.shared
        if let device = network.devices.first(where: { $0.macAddress == mac }),
           let subnet = network.subnets.first(where: { $0.id == device.subnetID })?.network {
            broadcasts.append(subnet.broadcast)
        } else if let local = LocalNetworkContext.interfaces().first?.network {
            broadcasts.append(local.broadcast)
        }
        broadcasts.append(IPv4Address(0xFFFF_FFFF))
        return broadcasts
    }

    func wake() {
        guard let mac = MACAddress(wakeMAC.trimmingCharacters(in: .whitespaces)) else {
            wakeFailed = true
            wakeMessage = AppLocale.string("Enter a MAC address such as 00:11:22:33:44:55.")
            return
        }
        let broadcasts = wakeBroadcasts(for: mac)
        let sent = WakeOnLAN.send(to: mac, broadcasts: broadcasts)
        wakeFailed = sent == 0
        let targets = broadcasts.map(\.description).joined(separator: ", ")
        wakeMessage = sent == 0 ? AppLocale.string("The magic packet couldn't be sent. Check Local Network access in Privacy & Security.")
            : AppLocale.string("Sent \(sent) magic packets for \(mac.description) to \(targets).")
    }

    /// Devices with a known hardware address, for picking one to wake.
    var wakeableDevices: [NetworkDevice] {
        NetworkViewModel.shared.devices.filter { $0.macAddress != nil && !$0.hasPrivateMAC }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Opening from elsewhere

    /// Opens a tool with its input filled in, and starts it when that needs no further choice.
    func open(_ tool: NetworkTool, target: String) {
        self.tool = tool
        switch tool {
        case .ping: pingHost = target; startPing()
        case .traceroute: traceHost = target; startTrace()
        case .dns: dnsName = target; lookUp()
        case .ports: portHost = target
        case .whois: whoisQuery = target; runWhois()
        case .http: httpURL = target; runHTTPCheck()
        case .wake: wakeMAC = target
        }
    }

    // MARK: Results as text

    func resultText() -> String? {
        switch tool {
        case .ping:
            guard let target = pingTarget else { return nil }
            let stats = pingStats
            var lines = ["PING \(pingHost) (\(target))"]
            lines += pingReplies.map { reply in
                if let ms = reply.milliseconds {
                    return "seq=\(reply.sequence) from \(reply.from ?? "?") time=\(String(format: "%.1f", ms)) ms" + (reply.ttl.map { " ttl=\($0)" } ?? "")
                }
                return "seq=\(reply.sequence) " + (reply.problem ?? "timeout")
            }
            lines.append("\(stats.sent) sent, \(stats.received) received, \(String(format: "%.0f", stats.lossPercent))% loss")
            if let min = stats.minimum, let avg = stats.average, let max = stats.maximum {
                lines.append(String(format: "min/avg/max/stddev = %.1f/%.1f/%.1f/%.1f ms", min, avg, max, stats.standardDeviation ?? 0))
            }
            return lines.joined(separator: "\n")
        case .traceroute:
            guard let target = traceTarget else { return nil }
            var lines = ["TRACEROUTE \(traceHost) (\(target)), \(trace.rounds) rounds", "hop  loss  avg  best  worst  host"]
            for hop in trace.hops {
                let host = hop.addresses.map { address in [hopNames[address], address.description, hopNetworks[address]].compactMap { $0 }.joined(separator: " ") }
                let times = [hop.average, hop.best, hop.worst].map { $0.map { String(format: "%.1f", $0) } ?? "*" }
                lines.append("\(hop.ttl)  \(String(format: "%.0f%%", hop.lossPercent))  \(times.joined(separator: "  "))  \(host.isEmpty ? "*" : host.joined(separator: " / "))")
            }
            return lines.joined(separator: "\n")
        case .dns:
            guard let name = dnsQueryName, !dnsRuns.isEmpty else { return nil }
            return dnsRuns.map { run in
                var lines = [";; \(name) \(dnsType.rawValue) @\(run.server) (\(run.label))"]
                if let result = run.result {
                    lines.append(";; \(result.rcodeName), \(String(format: "%.0f", result.milliseconds)) ms")
                    lines += (result.answers + result.authority).map { "\($0.name)\t\($0.ttl)\t\($0.type)\t\($0.value)" }
                } else if let error = run.error {
                    lines.append(";; \(error)")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        case .ports:
            guard let target = portTarget else { return nil }
            return (["PORTS \(portHost) (\(target))"] + portResults.map { "\($0.port)/tcp \($0.state.rawValue)" + (NetworkDeviceDetailView.serviceName($0.port).map { " \($0)" } ?? "") })
                .joined(separator: "\n")
        case .whois:
            return whoisOutput
        case .http:
            guard let result = httpResult else { return nil }
            var lines = ["\(result.requestedURL) → \(result.status.map(String.init) ?? "-") \(result.finalURL ?? "")"]
            lines += result.redirects.map { "\($0.status) \($0.url) → \($0.location)" }
            lines += result.headers.map { "\($0.name): \($0.value)" }
            return lines.joined(separator: "\n")
        case .wake:
            return nil
        }
    }
}
