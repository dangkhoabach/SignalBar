import Foundation
import GRDB
import Testing
@testable import SignalBarCore

/// Scheduled cleanup is the only thing in this app that deletes the user's
/// files unattended, so these test the refusals more than the happy path.
@Suite struct ScheduledCleanupTests {
    private final class RecordingCleanupRunner: CleanupRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _cleaned: [[JunkTarget]] = []
        private let available: [JunkTarget]
        private let result: (bytes: Int64, skipped: [String])

        init(
            available: [JunkTarget],
            result: (bytes: Int64, skipped: [String]) = (1_048_576, [])
        ) {
            self.available = available
            self.result = result
        }

        var cleaned: [[JunkTarget]] { lock.withLock { _cleaned } }

        func availableTargets() async -> [JunkTarget] { available }

        func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String]) {
            lock.withLock { _cleaned.append(targets) }
            return result
        }
    }

    /// Blocks inside `clean` until released, so a test can observe whether
    /// the tick came back while the cleanup was still going.
    private actor GatedCleanupRunner: CleanupRunning {
        private let available: [JunkTarget]
        private(set) var started = false
        private(set) var finished = false
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false

        init(available: [JunkTarget]) { self.available = available }

        func availableTargets() async -> [JunkTarget] { available }

        func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String]) {
            started = true
            if !released {
                await withCheckedContinuation { gate = $0 }
            }
            finished = true
            return (1, [])
        }

        func release() {
            released = true
            gate?.resume()
            gate = nil
        }
    }

    private final class RecordingNotifier: NotificationSending, @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [(title: String, body: String)] = []

        var messages: [(title: String, body: String)] { lock.withLock { _messages } }

        func notify(title: String, body: String, route: String?) async {
            lock.withLock { _messages.append((title, body)) }
        }
    }

    private struct NeverSends: ReportSending {
        func sendReport(label: String, days: Int) async -> Bool { false }
    }

    private struct SilentWebhook: AlertWebhookSending {
        func send(title: String, body: String, route: String?) async {}
    }

    private static let cache = JunkTarget(
        name: "App caches", detail: "", path: "/home/me/Library/Caches",
        mode: .contents, deletesPermanently: false
    )
    private static let derivedData = JunkTarget(
        name: "DerivedData", detail: "", path: "/home/me/Library/Developer/Xcode/DerivedData",
        mode: .contents, deletesPermanently: false
    )
    private static let trash = JunkTarget(
        name: "Trash", detail: "", path: "/home/me/.Trash",
        mode: .contents, deletesPermanently: true
    )

    private func makeScheduler(
        runner: CleanupRunning?,
        notifier: NotificationSending,
        configure: (inout AppSettings) -> Void
    ) throws -> (Scheduler, SchedulerStateStore) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        var settings = AppSettings.defaults
        settings.notificationsEnabled = true
        settings.cleanupScheduleEnabled = true
        settings.cleanupFrequency = "daily"
        configure(&settings)
        try SettingsRepository(dbQueue: app.dbQueue).update(settings)

        let scheduler = Scheduler(
            dbQueue: app.dbQueue,
            notifier: notifier,
            reportSender: NeverSends(),
            webhookSender: SilentWebhook(),
            remoteStatsProvider: nil,
            cleanupRunner: runner
        )
        return (scheduler, SchedulerStateStore(dbQueue: app.dbQueue))
    }

    // MARK: - Target filtering

    /// The rule the whole feature rests on. Emptying the Trash cannot be
    /// undone, so no schedule may ever do it — even if the stored selection
    /// names it.
    @Test func theTrashIsNeverCleanedOnASchedule() {
        let targets = JunkTarget.scheduledCleaningTargets(
            from: [Self.trash.path, Self.cache.path],
            available: [Self.trash, Self.cache]
        )

        #expect(targets.map(\.path) == [Self.cache.path])
    }

    @Test func everyRealTrashTargetIsExcluded() {
        let permanent = JunkTarget.defaults(homeDirectory: "/home/me").filter(\.deletesPermanently)
        #expect(!permanent.isEmpty) // guard against the fixture quietly changing
        #expect(permanent.allSatisfy { !$0.isEligibleForScheduledCleaning })
    }

    /// A path saved by an older build that this build no longer offers must
    /// simply not be cleaned.
    @Test func aSavedPathThatNoLongerExistsIsDropped() {
        let targets = JunkTarget.scheduledCleaningTargets(
            from: ["/home/me/Library/Caches/gone-in-this-build", Self.cache.path],
            available: [Self.cache]
        )

        #expect(targets.map(\.path) == [Self.cache.path])
    }

    @Test func nestedSelectionsAreCollapsedTheSameWayAManualCleanDoes() {
        let nested = JunkTarget(
            name: "SwiftPM", detail: "", path: Self.cache.path + "/org.swift.swiftpm",
            mode: .contents, deletesPermanently: false
        )
        let targets = JunkTarget.scheduledCleaningTargets(
            from: [Self.cache.path, nested.path], available: [Self.cache, nested]
        )

        #expect(targets.map(\.path) == [Self.cache.path])
    }

    // MARK: - Scheduling

    @Test func aDueRunCleansTheSelectedLocationsAndSaysSo() async throws {
        let runner = RecordingCleanupRunner(available: [Self.cache, Self.derivedData])
        let notifier = RecordingNotifier()
        let (scheduler, state) = try makeScheduler(runner: runner, notifier: notifier) {
            $0.cleanupTargetPaths = "\(Self.cache.path)\n\(Self.derivedData.path)"
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(runner.cleaned.count == 1)
        #expect(runner.cleaned.first?.count == 2)
        #expect(try state.lastCleanupPeriod().isEmpty == false)
        #expect(notifier.messages.first?.title == "Dọn dẹp theo lịch đã xong")
    }

    /// The tick runs every 15 seconds; without the period guard a daily
    /// schedule would clean continuously all day.
    @Test func asecondTickInTheSamePeriodCleansNothing() async throws {
        let runner = RecordingCleanupRunner(available: [Self.cache])
        let (scheduler, _) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.cleanupTargetPaths = Self.cache.path
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()
        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(runner.cleaned.count == 1)
    }

    @Test func nothingRunsWhileTheScheduleIsOff() async throws {
        let runner = RecordingCleanupRunner(available: [Self.cache])
        let (scheduler, _) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.cleanupScheduleEnabled = false
            $0.cleanupTargetPaths = Self.cache.path
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(runner.cleaned.isEmpty)
    }

    @Test func anEmptySelectionCleansNothing() async throws {
        let runner = RecordingCleanupRunner(available: [Self.cache])
        let (scheduler, _) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.cleanupTargetPaths = ""
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(runner.cleaned.isEmpty)
    }

    /// A selection made entirely of ineligible targets must not become "clean
    /// everything" or "clean nothing, but quietly mark the period done".
    @Test func aSelectionOfOnlyTheTrashCleansNothing() async throws {
        let runner = RecordingCleanupRunner(available: [Self.trash])
        let (scheduler, state) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.cleanupTargetPaths = Self.trash.path
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(runner.cleaned.isEmpty)
        #expect(try state.lastCleanupPeriod().isEmpty)
    }

    /// Partial failures have to reach the user; a run that silently half
    /// worked is the state this app keeps being audited for.
    @Test func whatCouldNotBeClearedIsNamedInTheNotification() async throws {
        let runner = RecordingCleanupRunner(
            available: [Self.cache], result: (0, ["App caches"])
        )
        let notifier = RecordingNotifier()
        let (scheduler, _) = try makeScheduler(runner: runner, notifier: notifier) {
            $0.cleanupTargetPaths = Self.cache.path
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        let body = try #require(notifier.messages.first?.body)
        #expect(body.contains("Chưa dọn hết"))
        #expect(body.contains("App caches"))
    }

    /// The tick is what runs every HTTP check. A cleanup that takes minutes
    /// must not hold it, or domain monitoring pauses for the whole run.
    @Test func aSlowCleanupDoesNotHoldTheTick() async throws {
        let runner = GatedCleanupRunner(available: [Self.cache])
        let (scheduler, _) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.cleanupTargetPaths = Self.cache.path
        }

        let tick = Task { await scheduler.tick() }
        let tickReturnedFirst = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await tick.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // A tick that awaits the cleanup can only come back once the
                // gate opens, and the group cannot drain until it does — so
                // the timeout opens it. Without this the test deadlocked
                // under exactly the regression it exists to catch.
                await runner.release()
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        #expect(tickReturnedFirst, "tick() waited for the cleanup to finish")
        #expect(await runner.started)
        await runner.release()
        await scheduler.waitForBackgroundWork()
        await tick.value
        #expect(await runner.finished)
    }

    /// Notifications can be off. The Settings page still has to be able to
    /// say what the last run did.
    @Test func whatTheRunDidIsRecordedForTheSettingsPage() async throws {
        let runner = RecordingCleanupRunner(available: [Self.cache, Self.derivedData], result: (3_000_000, ["DerivedData"]))
        let (scheduler, state) = try makeScheduler(runner: runner, notifier: RecordingNotifier()) {
            $0.notificationsEnabled = false
            $0.cleanupTargetPaths = "\(Self.cache.path)\n\(Self.derivedData.path)"
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        let run = try #require(try state.lastCleanupRun())
        #expect(run.bytes == 3_000_000)
        #expect(run.locations == 2)
        #expect(run.skipped == ["DerivedData"])
    }

    /// A host that never wired up a runner must behave as if the feature does
    /// not exist, even with the setting switched on.
    @Test func withoutARunnerTheScheduleIsInert() async throws {
        let (scheduler, state) = try makeScheduler(runner: nil, notifier: RecordingNotifier()) {
            $0.cleanupTargetPaths = Self.cache.path
        }

        await scheduler.tick()
        await scheduler.waitForBackgroundWork()

        #expect(try state.lastCleanupPeriod().isEmpty)
    }
}
