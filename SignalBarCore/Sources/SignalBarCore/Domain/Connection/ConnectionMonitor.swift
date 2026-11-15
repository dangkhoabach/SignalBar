import Foundation
import GRDB
import Network

/// What macOS says about the current route to the internet.
public struct PathSummary: Sendable, Equatable {
    public enum Kind: String, Sendable { case wifi, ethernet, cellular, other }

    public var isSatisfied: Bool
    public var kind: Kind?
    /// A hotspot or other connection the system treats as metered.
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    public var hasIPv4: Bool
    public var hasIPv6: Bool

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        kind = path.availableInterfaces.first.map { interface in
            switch interface.type {
            case .wifi: .wifi
            case .wiredEthernet: .ethernet
            case .cellular: .cellular
            default: .other
            }
        }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        hasIPv4 = path.supportsIPv4
        hasIPv6 = path.supportsIPv6
    }

    public init(isSatisfied: Bool, kind: Kind?, isExpensive: Bool = false, isConstrained: Bool = false,
                hasIPv4: Bool = true, hasIPv6: Bool = false) {
        self.isSatisfied = isSatisfied
        self.kind = kind
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.hasIPv4 = hasIPv4
        self.hasIPv6 = hasIPv6
    }
}

/// Everything the Connection page shows apart from the live charts.
public struct ConnectionStatus: Sendable, Equatable {
    public var path: PathSummary?
    public var local = LocalConnection()
    public var lookupEnabled = true
    public var publicIPv4: PublicAddress?
    public var publicIPv6: PublicAddress?
    /// A public 1.1.1.1 answered a ping during the last refresh.
    public var internetReachable: Bool?
    /// The first hops past this Mac; `[0]` is normally the router.
    public var hops: [RouteHop?] = []
    public var natLayout: NATLayout = .unknown
    public var dnsTimings: [DNSServerTiming] = []
    /// The resolver that really asks the internet, and whose network it is in.
    public var dnsEgress: PublicAddress?
    public var refreshedAt: Date?
    public var isRefreshing = false

    public init() {}

    /// The router's next hop, where the provider's network starts.
    public var providerHop: IPv4Address? {
        hops.count > 1 ? hops[1]?.address : nil
    }
}

/// Keeps `ConnectionStatus` current: on start, when the Mac changes
/// networks, every ten minutes, and when asked. Records each public address
/// in the history and alerts when it changes, if that was asked for.
public actor ConnectionMonitor {
    static let refreshIntervalSecs: UInt64 = 600
    /// Joining a network takes a few seconds to settle (DHCP, then IPv6, then
    /// a VPN reconnecting); one refresh after that, not one per step.
    static let settleSecs: UInt64 = 5
    static let internetProbe = IPv4Address("1.1.1.1")!

    private let repo: ConnectionRepository
    private let settingsRepo: SettingsRepository
    private let lookup: PublicAddressLookup
    private let notifier: NotificationSending
    private let webhookSender: AlertWebhookSending
    private let alertText: AlertTextLocalizing

    private var status = ConnectionStatus()
    private var onUpdate: (@Sendable (ConnectionStatus) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var refreshTask: Task<Void, Never>?
    private var networks: [String: (asn: Int, holder: String)] = [:]

    public init(
        dbQueue: DatabaseQueue,
        notifier: NotificationSending,
        webhookSender: AlertWebhookSending? = nil,
        alertText: AlertTextLocalizing = EnglishAlertText(),
        lookup: PublicAddressLookup = PublicAddressLookup()
    ) {
        repo = ConnectionRepository(dbQueue: dbQueue)
        settingsRepo = SettingsRepository(dbQueue: dbQueue)
        self.lookup = lookup
        self.notifier = notifier
        self.webhookSender = webhookSender ?? WebhookAlertSender(dbQueue: dbQueue)
        self.alertText = alertText
    }

    public func start(onUpdate: @escaping @Sendable (ConnectionStatus) -> Void) {
        self.onUpdate = onUpdate
        guard loopTask == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = PathSummary(path)
            Task { await self?.pathDidChange(summary) }
        }
        monitor.start(queue: DispatchQueue(label: "SignalBar.ConnectionMonitor.path"))
        pathMonitor = monitor
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        settleTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    public var current: ConnectionStatus { status }

    private func pathDidChange(_ path: PathSummary) {
        let first = status.path == nil
        status.path = path
        publish()
        guard !first else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleSecs * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reads everything again. A refresh already running is waited for, not doubled.
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        status.isRefreshing = true
        publish()
        let settings = (try? settingsRepo.load()) ?? .defaults
        let lookupEnabled = settings.connectionPublicLookupEnabled
        let local = SystemNetworkReader.read()
        let hasGlobalIPv6 = local.primary?.ipv6.contains { $0.kind != .linkLocal } ?? false
        let throughVPN = local.vpnCarriesAllTraffic
        let lookup = lookup

        async let v4 = lookupEnabled ? lookup.address(.ipv4) : nil
        async let v6 = lookupEnabled && hasGlobalIPv6 ? lookup.address(.ipv6) : nil
        async let egressIP = lookupEnabled ? DNSChecks.resolverEgress() : nil
        async let timings = DNSChecks.timings(local.dns.servers)
        async let reachable = runBlocking { cancel in
            EchoProbe.round([Self.internetProbe], timeout: 1.5, cancel: cancel)
        }
        // Through a full tunnel the hops are the VPN's, not the provider's.
        async let hops = local.primary?.router == nil || throughVPN ? [] : runBlocking { cancel in
            EchoProbe.firstHops(towards: Self.internetProbe, maxHops: 3, timeout: 1, cancel: cancel)
        }

        var next = status
        next.local = local
        next.lookupEnabled = lookupEnabled
        next.hops = await hops
        next.natLayout = throughVPN ? .unknown : NATLayout.classify(hops: next.hops.map { $0?.address })
        next.dnsTimings = await timings
        next.internetReachable = !(await reachable).isEmpty
        next.publicIPv4 = await completed(v4, lookupEnabled: lookupEnabled)
        next.publicIPv6 = await completed(v6, lookupEnabled: lookupEnabled)
        if let ip = await egressIP {
            next.dnsEgress = await completed(PublicAddress(family: .ipv4, ip: ip), lookupEnabled: lookupEnabled, reverse: false)
        } else {
            next.dnsEgress = nil
        }
        next.refreshedAt = Date()
        next.isRefreshing = false
        // Recorded before the status goes out, so a page reloading the
        // history on it sees this refresh's addresses.
        for address in [next.publicIPv4, next.publicIPv6].compactMap({ $0 }) {
            await record(address, settings: settings)
        }
        // The path may have changed while this ran; keep the newer one.
        next.path = status.path
        status = next
        publish()
    }

    /// Adds the network's owner and the address's name.
    private func completed(_ address: PublicAddress?, lookupEnabled: Bool, reverse: Bool = true) async -> PublicAddress? {
        guard var address else { return nil }
        if lookupEnabled {
            if let known = networks[address.ip] {
                (address.asn, address.holder) = (known.asn, known.holder)
            } else if let found = await lookup.network(of: address.ip) {
                networks[address.ip] = found
                (address.asn, address.holder) = (found.asn, found.holder)
            }
        }
        if reverse {
            address.reverseName = await PublicAddressLookup.reverseName(of: address.ip)
        }
        return address
    }

    private func record(_ address: PublicAddress, settings: AppSettings) async {
        guard let previous = try? repo.record(address), settings.connectionAlertPublicIPChange else { return }
        let message = AlertMessage.publicIPChanged(old: previous.ip, new: address.ip, holder: address.holder)
        let (title, body) = alertText.text(for: message)
        if settings.notificationsEnabled {
            await notifier.notify(title: title, body: body, route: "/network/connection")
        }
        if settings.networkWebhookEnabled {
            await webhookSender.send(title: title, body: body, route: "/network/connection")
        }
    }

    private func publish() {
        onUpdate?(status)
    }
}
