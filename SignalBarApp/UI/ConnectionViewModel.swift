import AppKit
import CoreLocation
import Observation
import SignalBarCore

/// Network › Connection: the status `ConnectionMonitor` keeps for the whole
/// app, plus the live readings (Wi-Fi signal, latency, throughput) taken
/// only while the page is open.
@MainActor
@Observable
final class ConnectionViewModel {
    static let shared = ConnectionViewModel(database: AppDatabase.shared)

    /// Live readings kept for the charts.
    static let liveWindow: TimeInterval = 600
    static let latencyEverySecs = 5
    static let throughputEverySecs = 2

    struct LatencySample: Identifiable, Equatable {
        var date: Date
        var gateway: Double?
        var provider: Double?
        var internet: Double?
        var id: Date { date }
    }

    struct ThroughputSample: Identifiable, Equatable {
        var date: Date
        var inBitsPerSecond: Double
        var outBitsPerSecond: Double
        var id: Date { date }
    }

    /// Average, jitter and loss over the readings in the window, for one target.
    struct LatencyStats: Equatable {
        var average: Double?
        /// Mean difference between consecutive answers.
        var jitter: Double?
        var lossPercent: Double
        var count: Int

        init(_ values: [Double?]) {
            count = values.count
            let answered = values.compactMap { $0 }
            average = answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count)
            jitter = answered.count < 2 ? nil
                : zip(answered, answered.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(answered.count - 1)
            lossPercent = values.isEmpty ? 0 : Double(values.count - answered.count) / Double(values.count) * 100
        }
    }

    private(set) var status = ConnectionStatus()
    private(set) var history: [PublicIPRecord] = []
    private(set) var wifi: WiFiStatus?
    private(set) var latency: [LatencySample] = []
    private(set) var throughput: [ThroughputSample] = []
    let wifiNameAccess = WiFiNameAccess()

    private let monitor: ConnectionMonitor?
    private let repo: ConnectionRepository?
    private var liveTask: Task<Void, Never>?
    private var liveViewers = 0
    private var lastCounters: InterfaceCounters?

    init(database: AppDatabase?) {
        monitor = database.map {
            ConnectionMonitor(dbQueue: $0.dbQueue, notifier: NotificationManager.shared, alertText: LocalizedAlertText())
        }
        repo = database.map { ConnectionRepository(dbQueue: $0.dbQueue) }
    }

    /// From `AppDelegate`: the status and history are kept for the app's
    /// lifetime, for the menu bar and the IP change alert.
    func start() {
        guard let monitor else { return }
        Task { [weak self] in
            await monitor.start { status in
                Task { @MainActor in self?.apply(status) }
            }
        }
    }

    func refresh() {
        guard let monitor else { return }
        Task { await monitor.refresh() }
    }

    private func apply(_ new: ConnectionStatus) {
        let finished = status.isRefreshing && !new.isRefreshing
        status = new
        if finished || history.isEmpty { reloadHistory() }
    }

    func reloadHistory() {
        history = (try? repo?.history()) ?? []
    }

    func clearHistory() {
        try? repo?.clearHistory()
        reloadHistory()
    }

    // MARK: - Live readings

    func startLive() {
        liveViewers += 1
        guard liveTask == nil else { return }
        wifiNameAccess.refresh()
        liveTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % Self.throughputEverySecs == 0 { self.readThroughputAndWiFi() }
                if tick % Self.latencyEverySecs == 0 { await self.readLatency() }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopLive() {
        liveViewers = max(0, liveViewers - 1)
        guard liveViewers == 0 else { return }
        liveTask?.cancel()
        liveTask = nil
        lastCounters = nil
    }

    private func readThroughputAndWiFi() {
        let next = WiFiStatus.read()
        if next != wifi { wifi = next }
        guard let name = status.local.primary?.name, let counters = InterfaceCounters.read(interface: name) else { return }
        defer { lastCounters = counters }
        guard let last = lastCounters, let rates = counters.rates(since: last) else { return }
        throughput.append(ThroughputSample(date: counters.readAt, inBitsPerSecond: rates.inBitsPerSecond, outBitsPerSecond: rates.outBitsPerSecond))
        throughput.removeAll { $0.date < counters.readAt.addingTimeInterval(-Self.liveWindow) }
    }

    private func readLatency() async {
        let gateway = status.local.primary?.router.flatMap(IPv4Address.init)
        let provider = status.providerHop
        let internet = IPv4Address("1.1.1.1")!
        let replies = await LatencyProbe.ping([gateway, provider, internet].compactMap { $0 })
        let now = Date()
        latency.append(LatencySample(date: now, gateway: gateway.flatMap { replies[$0] },
                                     provider: provider.flatMap { replies[$0] }, internet: replies[internet]))
        latency.removeAll { $0.date < now.addingTimeInterval(-Self.liveWindow) }
    }

    var gatewayStats: LatencyStats { LatencyStats(latency.map(\.gateway)) }
    var providerStats: LatencyStats { LatencyStats(latency.map(\.provider)) }
    var internetStats: LatencyStats { LatencyStats(latency.map(\.internet)) }

    // MARK: - Reading the status

    enum Reachability: Equatable {
        case checking, online, noInternet, offline
    }

    var reachability: Reachability { Self.reachability(status, lastInternetPing: latency.last?.internet) }

    nonisolated static func reachability(_ status: ConnectionStatus, lastInternetPing: Double?) -> Reachability {
        guard let path = status.path else { return .checking }
        guard path.isSatisfied else { return .offline }
        if status.refreshedAt == nil { return .checking }
        let reached = status.internetReachable == true || status.publicIPv4 != nil || status.publicIPv6 != nil
            || lastInternetPing != nil
        return reached ? .online : .noInternet
    }

    /// Where a slow connection is slow, from the averages: the first stretch
    /// that adds most of the delay.
    enum SlowStretch: Equatable {
        case localNetwork, provider, beyond
    }

    var slowStretch: SlowStretch? {
        Self.slowStretch(gateway: gatewayStats, provider: providerStats, internet: internetStats)
    }

    nonisolated static func slowStretch(gateway: LatencyStats, provider: LatencyStats, internet: LatencyStats) -> SlowStretch? {
        guard let internetAverage = internet.average, internetAverage >= 80 || internet.lossPercent >= 5 else { return nil }
        let gatewayAverage = gateway.average ?? 0
        if gatewayAverage >= 30 || gateway.lossPercent >= 5 { return .localNetwork }
        if let providerAverage = provider.average, providerAverage - gatewayAverage >= 30 { return .provider }
        return .beyond
    }

    /// The address shown in the menu bar: IPv4 first, people type it more.
    var primaryPublicIP: String? { status.publicIPv4?.ip ?? status.publicIPv6?.ip }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Location access, which macOS requires before it names the Wi-Fi network.
/// Asked only when the user clicks for it.
@MainActor
@Observable
final class WiFiNameAccess: NSObject, CLLocationManagerDelegate {
    enum State: Equatable { case notAsked, granted, denied }

    private(set) var state: State = .notAsked
    @ObservationIgnored private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    func refresh() {
        state = Self.state(manager.authorizationStatus)
    }

    func request() {
        if state == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.state = Self.state(status) }
    }

    private static func state(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .denied, .restricted: .denied
        default: .notAsked
        }
    }
}
