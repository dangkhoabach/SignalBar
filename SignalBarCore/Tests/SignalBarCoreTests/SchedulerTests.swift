import Foundation
import GRDB
import Testing
@testable import SignalBarCore

private actor RecordingNotifier: NotificationSending {
    private(set) var notifications: [(title: String, body: String, route: String?)] = []
    func notify(title: String, body: String, route: String?) async {
        notifications.append((title, body, route))
    }
}

private actor RecordingReportSender: ReportSending {
    private(set) var calls: [(label: String, days: Int)] = []
    func sendReport(label: String, days: Int) async -> Bool {
        calls.append((label, days))
        return true
    }
}

/// Suspends inside `sendReport` until released, so a second `tick()` can be
/// driven into the window where the first is mid-send — the shape that
/// produced two report emails on wake-from-sleep.
private actor SuspendingReportSender: ReportSending {
    private(set) var callCount = 0
    private var resume: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func sendReport(label: String, days: Int) async -> Bool {
        callCount += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { resume = $0 }
        return true
    }

    /// Waits until a send is actually in progress.
    func waitUntilSending() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}

/// Always fails, standing in for a relay that's down.
private actor FailingReportSender: ReportSending {
    private(set) var callCount = 0
    func sendReport(label: String, days: Int) async -> Bool {
        callCount += 1
        return false
    }
}

/// Holds the *first* `notify` open so a second `tick()` can be driven into
/// the window between reading an alert flag and setting it.
///
/// Only the first call parks. A second one returns straight away and is
/// counted — if the guard under test regresses, this fails on the count
/// instead of deadlocking two parked callers against a single release.
private actor SuspendingNotifier: NotificationSending {
    private(set) var notifications: [String] = []
    private var resume: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasParked = false

    func notify(title: String, body: String, route: String?) async {
        notifications.append(title)
        started?.resume()
        started = nil
        guard !hasParked else { return }
        hasParked = true
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilNotifying() async {
        guard notifications.isEmpty else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}

private struct StaticStatsProvider: SystemStatsProvider {
    let value: SystemStats
    func snapshot() async -> SystemStats { value }
}

private actor RecordingWebhookSender: AlertWebhookSending {
    private(set) var alerts: [(title: String, body: String, route: String?)] = []
    func send(title: String, body: String, route: String?) async {
        alerts.append((title, body, route))
    }
}

/// Serves canned stats for a fixed set of servers, and counts the polls, so
/// the cadence and the alert transitions can be driven without SSH.
private actor StaticRemoteStatsProvider: RemoteStatsProviding {
    private let servers: [RemoteServer]
    private var readings: [RemoteServerStats]
    private let failure: Error?
    private(set) var pollCount = 0

    init(servers: [RemoteServer], readings: [RemoteServerStats], failure: Error? = nil) {
        self.servers = servers
        self.readings = readings
        self.failure = failure
    }

    nonisolated func monitoredServers() throws -> [RemoteServer] { servers }

    func stats(for server: RemoteServer) async throws -> RemoteServerStats {
        pollCount += 1
        if let failure { throw failure }
        return readings.count > 1 ? readings.removeFirst() : (readings.first ?? RemoteServerStats())
    }
}

private struct PollFailure: Error {}

/// Server A waits (bounded) for server B's poll to begin. Under sequential
/// polling B never begins until A returns, so the wait times out and the
/// flag stays false.
private actor GatedRemoteStatsProvider: RemoteStatsProviding {
    private let servers: [RemoteServer]
    private let reading: RemoteServerStats
    private var bStarted = false
    private var waitingForB: CheckedContinuation<Void, Never>?
    private(set) var bStartedBeforeAFinished = false

    init(servers: [RemoteServer], reading: RemoteServerStats) {
        self.servers = servers
        self.reading = reading
    }

    nonisolated func monitoredServers() throws -> [RemoteServer] { servers }

    func stats(for server: RemoteServer) async throws -> RemoteServerStats {
        if server.name == "B" {
            bStarted = true
            resumeA()
            return reading
        }
        if !bStarted {
            // Bounded: under sequential polling nothing would ever resume
            // this, and a test that hangs is worse than one that fails.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.resumeA()
            }
            await withCheckedContinuation { waitingForB = $0 }
        }
        bStartedBeforeAFinished = bStarted
        return reading
    }

    private func resumeA() {
        waitingForB?.resume()
        waitingForB = nil
    }
}

@Suite struct SchedulerTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(inMemory: DatabaseQueue())
    }

    @Test func tickFiresDownAlertOnceThresholdReached() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = true; s.failureAlertThreshold = 1; return s }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender())

        await scheduler.tick()

        let notifications = await notifier.notifications
        #expect(notifications.count == 1)
        #expect(notifications[0].title.contains("đang down"))
    }

    @Test func tickSendsNoNotificationWhenNotificationsDisabled() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = false; s.failureAlertThreshold = 1; return s }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender())

        await scheduler.tick()

        #expect(await notifier.notifications.isEmpty)
    }

    @Test func tickSendsReportOnceWhenDailyReportIsDueThenDedupesOnSecondTick() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.smtpEnabled = true
            s.smtpRecipientEmail = "ops@example.com"
            // The relay only delivers to a verified address, so an unverified
            // install never even attempts a report.
            s.smtpVerifiedEmail = "ops@example.com"
            s.smtpFrequency = "daily"
            return s
        }())

        let reportSender = RecordingReportSender()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: reportSender)

        await scheduler.tick()
        await scheduler.tick()

        let calls = await reportSender.calls
        #expect(calls.count == 1)
        #expect(calls[0].label == "Daily")
    }

    @Test func tickFiresSystemTempAlertOnceThenClearsWhenCooled() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({ var s = AppSettings.defaults; s.notificationsEnabled = true; s.systemTempAlertThresholdCelsius = 80; return s }())

        let notifier = RecordingNotifier()
        let hotScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 90))
        )
        await hotScheduler.tick()
        await hotScheduler.tick() // still hot: must not alert again

        let afterHot = await notifier.notifications
        #expect(afterHot.count == 1)
        #expect(afterHot[0].title == "Nhiệt độ máy đang cao")

        let coolScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 50))
        )
        await coolScheduler.tick() // clears the flag, no new alert
        await hotScheduler.tick() // hot again: flag was cleared, must alert again

        let afterCycle = await notifier.notifications
        #expect(afterCycle.count == 2)
    }

    /// The whole reason a webhook exists: it reaches a channel that is being
    /// watched when nobody is at this Mac. Turning off local notifications
    /// must therefore not silence it.
    @Test func anAlertReachesTheWebhookEvenWithNotificationsTurnedOff() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.notificationsEnabled = false
            s.failureAlertThreshold = 1
            return s
        }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let webhook = RecordingWebhookSender()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            webhookSender: webhook
        )

        await scheduler.tick()

        #expect(await notifier.notifications.isEmpty)
        let alerts = await webhook.alerts
        #expect(alerts.count == 1)
        #expect(alerts[0].title.contains("đang down"))
    }

    /// And the reverse: a webhook nobody configured must not suppress or
    /// alter the local notification.
    @Test func bothDestinationsReceiveTheSameAlert() async throws {
        let app = try makeDatabase()
        let targetRepo = TargetRepository(dbQueue: app.dbQueue)
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.notificationsEnabled = true
            s.failureAlertThreshold = 1
            return s
        }())
        _ = try targetRepo.add(NewTargetInput(name: "Unreachable", url: "https://this-host-does-not-exist.invalid"))

        let notifier = RecordingNotifier()
        let webhook = RecordingWebhookSender()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            webhookSender: webhook
        )

        await scheduler.tick()

        let notifications = await notifier.notifications
        let alerts = await webhook.alerts
        #expect(notifications.count == 1)
        #expect(alerts.count == 1)
        #expect(notifications[0].title == alerts[0].title)
        #expect(notifications[0].route == alerts[0].route)
    }

    // MARK: - Remote server resource alerts

    private func monitoredServer(_ name: String = "Prod", id: Int64 = 1) -> RemoteServer {
        RemoteServer(
            id: id, name: name, host: "10.0.0.1", username: "deploy",
            authMethod: .password, keychainRef: "ref", monitoringEnabled: true
        )
    }

    private func loaded(cpu: Double) -> RemoteServerStats {
        var stats = RemoteServerStats()
        stats.cpu = RemoteCPUUsage(busyPercent: cpu)
        return stats
    }

    private func remoteThresholdSettings(_ repo: SettingsRepository, cpu: Int) throws {
        try repo.update({
            var s = AppSettings.defaults
            s.notificationsEnabled = true
            s.remoteCPUAlertThresholdPercent = cpu
            return s
        }())
    }

    /// The default install must not start opening SSH connections it didn't
    /// open before: with no threshold set, nothing is polled at all.
    @Test func noRemotePollHappensWhileEveryThresholdIsOff() async throws {
        let app = try makeDatabase()
        let provider = StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [loaded(cpu: 99)])
        let notifier = RecordingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        await scheduler.tick()

        #expect(await provider.pollCount == 0)
        #expect(await notifier.notifications.isEmpty)
    }

    @Test func crossingAThresholdAlertsOnceAndNotAgainWhileItStaysHigh() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)
        let provider = StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [loaded(cpu: 95)])
        let notifier = RecordingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        await scheduler.tick()
        // Reset the cadence gate so the second tick polls rather than being
        // skipped for being too soon — the dedupe under test is the alert
        // flag, not the interval.
        try stateStore.markRemoteStatsPolled(at: .distantPast)
        await scheduler.tick()

        let notifications = await notifier.notifications
        #expect(await provider.pollCount == 2)
        #expect(notifications.count == 1)
        #expect(notifications[0].title == "Prod: CPU đang cao")
        #expect(notifications[0].body == "95% (ngưỡng 80%)")
    }

    @Test func droppingBackUnderTheThresholdArmsTheNextAlert() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)
        let provider = StaticRemoteStatsProvider(
            servers: [monitoredServer()],
            readings: [loaded(cpu: 95), loaded(cpu: 10), loaded(cpu: 91)]
        )
        let notifier = RecordingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        for _ in 0..<3 {
            try stateStore.markRemoteStatsPolled(at: .distantPast)
            await scheduler.tick()
        }

        #expect(await notifier.notifications.count == 2)
    }

    /// A reading that never arrived is not a recovery. Clearing the flag on a
    /// failed poll would make the next high reading alert all over again, and
    /// worse, would read as "it is fine now" when nothing was measured.
    @Test func aFailedPollLeavesAStandingAlertAlone() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)
        let notifier = RecordingNotifier()

        let highScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [loaded(cpu: 95)])
        )
        await highScheduler.tick()
        #expect(await notifier.notifications.count == 1)

        let failingScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [], failure: PollFailure())
        )
        try stateStore.markRemoteStatsPolled(at: .distantPast)
        await failingScheduler.tick()

        // Still armed: a high reading right after the failure is the same
        // ongoing incident, not a new one.
        try stateStore.markRemoteStatsPolled(at: .distantPast)
        await highScheduler.tick()
        #expect(await notifier.notifications.count == 1)
    }

    /// A poll that succeeds but comes back without this particular reading
    /// (`top` missing, output unparseable) is not a recovery either — and
    /// unlike a failed poll, this one reaches the clearing branch, so the
    /// distinction has to be made there rather than by never getting here.
    @Test func aSuccessfulPollMissingTheReadingLeavesAStandingAlertAlone() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)
        let notifier = RecordingNotifier()

        let highScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [loaded(cpu: 95)])
        )
        await highScheduler.tick()
        #expect(await notifier.notifications.count == 1)

        // Reading absent, every other field present: the poll worked, the
        // CPU figure just isn't in it.
        let blindScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [RemoteServerStats()])
        )
        try stateStore.markRemoteStatsPolled(at: .distantPast)
        await blindScheduler.tick()

        try stateStore.markRemoteStatsPolled(at: .distantPast)
        await highScheduler.tick()
        #expect(await notifier.notifications.count == 1)
    }

    /// Each server keeps its own flag, or one noisy box would mask every
    /// other one.
    @Test func eachServerAlertsIndependently() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let provider = StaticRemoteStatsProvider(
            servers: [monitoredServer("Prod", id: 1), monitoredServer("Staging", id: 2)],
            readings: [loaded(cpu: 95)]
        )
        let notifier = RecordingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        await scheduler.tick()

        let titles = await notifier.notifications.map(\.title)
        #expect(Set(titles) == ["Prod: CPU đang cao", "Staging: CPU đang cao"])
    }

    /// Ticks run every fifteen seconds; SSH-ing someone's server that often
    /// would make the monitoring a load on what it watches.
    @Test func aSecondTickWithinTheIntervalDoesNotPollAgain() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let provider = StaticRemoteStatsProvider(servers: [monitoredServer()], readings: [loaded(cpu: 10)])
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        await scheduler.tick()
        await scheduler.tick()

        #expect(await provider.pollCount == 1)
    }

    /// Sequential polling meant one dead server delayed every server behind
    /// it by a full connect timeout, and the tick with them. Server A's poll
    /// here refuses to answer until server B's has started — which can only
    /// happen if the two run at the same time.
    @Test func serversArePolledConcurrently() async throws {
        let app = try makeDatabase()
        try remoteThresholdSettings(SettingsRepository(dbQueue: app.dbQueue), cpu: 80)
        let provider = GatedRemoteStatsProvider(
            servers: [monitoredServer("A", id: 1), monitoredServer("B", id: 2)], reading: loaded(cpu: 10)
        )
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: RecordingReportSender(),
            remoteStatsProvider: provider
        )

        await scheduler.tick()

        #expect(await provider.bStartedBeforeAFinished)
    }

    @Test func theOutcomeOfEachReportAttemptIsRecorded() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)
        try makeReportSettings(settingsRepo)

        let failing = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: FailingReportSender())
        await failing.tick()
        let failed = try #require(try stateStore.lastReportOutcome())
        #expect(failed.sent == false)
        #expect(failed.label == "Daily")

        try stateStore.markReportAttempted(at: .distantPast)
        let succeeding = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: RecordingReportSender())
        await succeeding.tick()
        #expect(try stateStore.lastReportOutcome()?.sent == true)
    }

    private func makeReportSettings(_ settingsRepo: SettingsRepository) throws {
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.smtpEnabled = true
            s.smtpRecipientEmail = "ops@example.com"
            // The relay only delivers to a verified address, so an unverified
            // install never even attempts a report.
            s.smtpVerifiedEmail = "ops@example.com"
            s.smtpFrequency = "daily"
            return s
        }())
    }

    /// End-to-end cover for the wake-from-sleep path: a second `tick()`
    /// arriving while the first is parked mid-send must not produce a second
    /// email.
    ///
    /// Note this passes with or without `tickInFlight`, because recording the
    /// attempt *before* awaiting the send already closes this particular
    /// window. It's kept as the regression test for the reported symptom; the
    /// guard itself is exercised by the system-alert test below, where there
    /// is no backoff to fall back on.
    @Test func aSecondTickDuringASendDoesNotSendTheReportTwice() async throws {
        let app = try makeDatabase()
        try makeReportSettings(SettingsRepository(dbQueue: app.dbQueue))

        let sender = SuspendingReportSender()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: sender)

        let first = Task { await scheduler.tick() }
        await sender.waitUntilSending()

        // The wake-from-sleep path, arriving while the first tick is parked
        // mid-send.
        await scheduler.tick()

        await sender.release()
        await first.value

        #expect(await sender.callCount == 1)
    }

    /// What `tickInFlight` is actually for: the system-alert flags are a
    /// read-then-write around an `await`, with nothing else guarding them.
    /// Two reentrant ticks both read "not yet alerted" and both notified, so
    /// a wake-from-sleep during a hot spell produced a duplicate alert.
    @Test func aSecondTickDuringAnAlertDoesNotRaiseItTwice() async throws {
        let app = try makeDatabase()
        let settingsRepo = SettingsRepository(dbQueue: app.dbQueue)
        try settingsRepo.update({
            var s = AppSettings.defaults
            s.notificationsEnabled = true
            s.systemTempAlertThresholdCelsius = 80
            return s
        }())

        let notifier = SuspendingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier, reportSender: RecordingReportSender(),
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 95))
        )

        let first = Task { await scheduler.tick() }
        await notifier.waitUntilNotifying()
        await scheduler.tick()

        await notifier.release()
        await first.value

        #expect(await notifier.notifications.count == 1)
    }

    /// A failing relay must not turn the 15-second tick into an all-day retry
    /// loop: the due-today window stays open until a send succeeds, so the
    /// backoff is the only thing bounding the attempts.
    @Test func aFailedReportIsNotRetriedOnTheVeryNextTick() async throws {
        let app = try makeDatabase()
        try makeReportSettings(SettingsRepository(dbQueue: app.dbQueue))

        let sender = FailingReportSender()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: sender)

        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()

        #expect(await sender.callCount == 1)
    }

    /// Once the backoff has elapsed it does try again — the report still has
    /// to go out on a day the relay recovers.
    @Test func aFailedReportIsRetriedOnceTheBackoffElapses() async throws {
        let app = try makeDatabase()
        try makeReportSettings(SettingsRepository(dbQueue: app.dbQueue))
        let stateStore = SchedulerStateStore(dbQueue: app.dbQueue)

        let sender = FailingReportSender()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: sender)

        await scheduler.tick()
        try stateStore.markReportAttempted(
            at: Date().addingTimeInterval(-Scheduler.reportRetryIntervalSecs - 60)
        )
        await scheduler.tick()

        #expect(await sender.callCount == 2)
    }

    @Test func startAndStopDoNotCrash() async throws {
        let app = try makeDatabase()
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: RecordingNotifier(), reportSender: RecordingReportSender())
        await scheduler.start()
        await scheduler.stop()
    }
}

@Suite struct SchedulerAlertDecisionTests {
    private func transition(
        previousFailures: Int = 0, newFailures: Int = 0,
        previousSlow: Int = 0, newSlow: Int = 0, isSlow: Bool = false
    ) -> TargetRepository.AlertTransition {
        TargetRepository.AlertTransition(
            previousFailures: previousFailures, newFailures: newFailures,
            previousSlow: previousSlow, newSlow: newSlow, isSlow: isSlow
        )
    }

    /// The regression this suite exists for: a target that answered slowly for
    /// `threshold` checks and then failed outright used to report "response
    /// time back to normal" — the reassuring message, at the exact moment it
    /// started going down. A failed check never means the response time
    /// recovered, so it must produce no alert until the failure streak
    /// reaches the threshold.
    @Test func aFailureAfterASlowStreakDoesNotClaimTheResponseTimeRecovered() {
        let firstFailure = transition(previousFailures: 0, newFailures: 1, previousSlow: 2, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: false, transition: firstFailure, threshold: 2) == nil)
    }

    /// The down alert still arrives on the check that reaches the threshold,
    /// so the slow streak only delays it, never replaces it.
    @Test func theDownAlertStillFiresOnceTheFailureStreakReachesTheThreshold() {
        let secondFailure = transition(previousFailures: 1, newFailures: 2, previousSlow: 0, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: false, transition: secondFailure, threshold: 2) == .down)
    }

    /// A genuine response-time recovery — a successful, no-longer-slow check
    /// after a slow streak — must still alert.
    @Test func aSuccessfulFastCheckAfterASlowStreakReportsTheRecovery() {
        let recovered = transition(previousFailures: 0, newFailures: 0, previousSlow: 2, newSlow: 0, isSlow: false)
        #expect(Scheduler.alert(success: true, transition: recovered, threshold: 2) == .responseTimeNormal)
    }

    @Test func aSlowStreakReachingTheThresholdReportsSlow() {
        let slow = transition(previousSlow: 1, newSlow: 2, isSlow: true)
        #expect(Scheduler.alert(success: true, transition: slow, threshold: 2) == .slow)
    }

    @Test func aSuccessAfterAFailureStreakReportsBackUp() {
        let backUp = transition(previousFailures: 2, newFailures: 0)
        #expect(Scheduler.alert(success: true, transition: backUp, threshold: 2) == .backUp)
    }

    /// Steady state on both sides: nothing to say.
    @Test func anUneventfulCheckProducesNoAlert() {
        #expect(Scheduler.alert(success: true, transition: transition(), threshold: 2) == nil)
        #expect(Scheduler.alert(success: false, transition: transition(newFailures: 1), threshold: 2) == nil)
    }
}
