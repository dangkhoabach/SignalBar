import Foundation
import GRDB

/// Periodic tick loop: runs due HTTP/SSL/domain checks, sends alert
/// notifications on state transitions, and handles report/history/system-
/// alert bookkeeping — the native equivalent of `scheduler.rs`.
///
/// Uses a `Task.sleep`-based loop rather than `tokio::time::interval`'s
/// Swift/Foundation equivalent (`Timer`/`DispatchSourceTimer`). Each
/// iteration sleeps a fixed duration *after* finishing its work, so there's
/// nothing to "catch up" on after the process was suspended by system sleep
/// — this is the exact bug the Rust version had (`MissedTickBehavior::Burst`)
/// and fixed by switching to `Delay`; this loop shape doesn't have the
/// failure mode to begin with.
public actor Scheduler {
    public static let tickIntervalSecs: UInt64 = 15
    private static let expiryCheckIntervalSecs = 86_400

    private let targetRepo: TargetRepository
    private let settingsRepo: SettingsRepository
    private let stateStore: SchedulerStateStore
    private let notifier: NotificationSending
    private let reportSender: ReportSending
    private let statsProvider: SystemStatsProvider?

    private var loopTask: Task<Void, Never>?
    /// Target IDs with an HTTP check currently in flight - guards against
    /// `checkNow`/`checkAllNow` racing the periodic `tick`'s own
    /// `runHTTPChecks` for the same target. Both call into
    /// `runHTTPChecks(on:)`, which awaits across `HttpChecker.check` and
    /// `storeCheckResult`; without this, two concurrent checks for the same
    /// target could land their `storeCheckResult` writes out of order,
    /// scrambling the failure/slow-streak counters `AlertTransition` relies
    /// on (missed or doubled alerts).
    private var inFlightTargetIds: Set<Int64> = []

    public init(
        dbQueue: DatabaseQueue,
        notifier: NotificationSending,
        reportSender: ReportSending,
        statsProvider: SystemStatsProvider? = nil
    ) {
        self.targetRepo = TargetRepository(dbQueue: dbQueue)
        self.settingsRepo = SettingsRepository(dbQueue: dbQueue)
        self.stateStore = SchedulerStateStore(dbQueue: dbQueue)
        self.notifier = notifier
        self.reportSender = reportSender
        self.statsProvider = statsProvider
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: Self.tickIntervalSecs * 1_000_000_000)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Runs one cycle immediately — used both by the periodic loop and by the
    /// app's `NSWorkspace.didWakeNotification` handler (Core has no AppKit
    /// dependency, so it can't observe that notification itself; see D6).
    public func tick() async {
        do {
            try await runHTTPChecks()
            try await runExpiryChecks()
            try await maybeSendReport()
            try stateStore.cleanupHistoryIfDue(retentionDays: try settingsRepo.load().historyRetentionDays)
            await checkSystemAlerts()
        } catch {
            // Best-effort background loop: log and keep ticking next cycle
            // rather than letting one bad read/write kill the scheduler.
            print("Scheduler tick error: \(error)")
        }
    }

    // MARK: - HTTP checks

    private func runHTTPChecks() async throws {
        let due = try targetRepo.dueForHTTPCheck()
        guard !due.isEmpty else { return }
        try await runHTTPChecks(on: due)
    }

    /// Runs HTTP checks immediately for specific targets, bypassing the
    /// due-schedule gate — backs the Overview's "Check Now"/"Check All Now".
    public func checkNow(targetIds: [Int64]) async {
        guard !targetIds.isEmpty,
              let targets = try? targetRepo.list().filter({ targetIds.contains($0.id ?? -1) && $0.checkHTTP }),
              !targets.isEmpty
        else { return }
        try? await runHTTPChecks(on: targets)
    }

    private func runHTTPChecks(on targets: [Target]) async throws {
        let settings = try settingsRepo.load()

        // Skip any target whose check is already in flight (from tick or a
        // concurrent checkNow) rather than starting a second overlapping one.
        let runnable = targets.filter { !inFlightTargetIds.contains($0.id ?? -1) }
        guard !runnable.isEmpty else { return }
        for target in runnable { inFlightTargetIds.insert(target.id ?? -1) }
        defer { for target in runnable { inFlightTargetIds.remove(target.id ?? -1) } }

        await withTaskGroup(of: (Target, HttpCheckOutcome).self) { group in
            for target in runnable {
                group.addTask {
                    (target, await HttpChecker.check(target: target))
                }
            }
            for await (target, outcome) in group {
                await storeAndNotify(target: target, outcome: outcome, settings: settings)
            }
        }
    }

    private func storeAndNotify(target: Target, outcome: HttpCheckOutcome, settings: AppSettings) async {
        guard let targetId = target.id,
              let transition = try? targetRepo.storeCheckResult(targetId: targetId, outcome: outcome, responseTimeAlertThresholdMs: settings.responseTimeAlertThresholdMs)
        else { return }

        let route = "/targets/\(targetId)"
        switch Self.alert(success: outcome.success, transition: transition, threshold: settings.failureAlertThreshold) {
        case .down:
            await notifyIfEnabled(title: "\(target.name) đang down", body: outcome.errorMessage ?? "Health check thất bại", route: route)
        case .backUp:
            await notifyIfEnabled(title: "\(target.name) đã hoạt động lại", body: "Health check đã thành công", route: route)
        case .slow:
            await notifyIfEnabled(
                title: "\(target.name) phản hồi chậm",
                body: "\(outcome.responseTimeMs)ms (ngưỡng \(settings.responseTimeAlertThresholdMs)ms)",
                route: route
            )
        case .responseTimeNormal:
            await notifyIfEnabled(title: "\(target.name) đã phản hồi bình thường trở lại", body: "Response time đã ổn định", route: route)
        case nil:
            break
        }
    }

    enum Alert: Equatable {
        case down, backUp, slow, responseTimeNormal
    }

    /// Which alert a check transition warrants, if any.
    ///
    /// Pure and separate from `storeAndNotify` so the branch order can be
    /// tested directly: reproducing "slow but successful" through `tick()`
    /// would need a server that answers slowly on demand.
    static func alert(success: Bool, transition: TargetRepository.AlertTransition, threshold: Int) -> Alert? {
        if !success && transition.newFailures == threshold { return .down }
        if success && transition.previousFailures >= threshold { return .backUp }
        if transition.newSlow == threshold { return .slow }
        // `success` matters here even though `isSlow` is already false on any
        // failed check: without it, a target that was slow for `threshold`
        // checks and then failed outright reported "response time back to
        // normal" at the exact moment it started going down. The real down
        // alert only follows once the failure streak reaches `threshold`.
        if success && !transition.isSlow && transition.previousSlow >= threshold { return .responseTimeNormal }
        return nil
    }

    // MARK: - SSL / domain expiry checks

    private enum ExpiryOutcome {
        case ssl(Target, Date?)
        case domain(Target, Date?)
    }

    private func runExpiryChecks() async throws {
        let sslDue = try targetRepo.dueForSSLCheck(intervalSecs: Self.expiryCheckIntervalSecs)
        let domainDue = try targetRepo.dueForDomainCheck(intervalSecs: Self.expiryCheckIntervalSecs)
        guard !sslDue.isEmpty || !domainDue.isEmpty else { return }
        let settings = try settingsRepo.load()

        await withTaskGroup(of: ExpiryOutcome?.self) { group in
            for target in sslDue {
                group.addTask {
                    guard let host = HostParsing.extractHost(fromURL: target.url) else { return nil }
                    return .ssl(target, await ExpiryChecker.checkSSLExpiry(host: host))
                }
            }
            for target in domainDue {
                group.addTask {
                    guard let host = HostParsing.extractHost(fromURL: target.url) else { return nil }
                    let domain = HostParsing.extractRegistrableDomain(host)
                    return .domain(target, await ExpiryChecker.checkDomainExpiry(domain: domain))
                }
            }
            for await outcome in group {
                switch outcome {
                case .ssl(let target, let expiry):
                    await storeSSLResult(target: target, expiry: expiry, thresholdDays: settings.sslAlertThresholdDays)
                case .domain(let target, let expiry):
                    await storeDomainResult(target: target, expiry: expiry, thresholdDays: settings.domainAlertThresholdDays)
                case nil:
                    break
                }
            }
        }
    }

    private func storeSSLResult(target: Target, expiry: Date?, thresholdDays: Int) async {
        guard let targetId = target.id,
              let transition = try? targetRepo.storeSSLStatus(targetId: targetId, expiryDate: expiry, thresholdDays: thresholdDays)
        else { return }
        if transition.shouldAlert, let days = transition.daysRemaining {
            await notifyIfEnabled(title: "SSL sắp hết hạn: \(target.name)", body: "Còn \(days) ngày", route: "/targets/\(targetId)")
        }
    }

    private func storeDomainResult(target: Target, expiry: Date?, thresholdDays: Int) async {
        guard let targetId = target.id,
              let transition = try? targetRepo.storeDomainStatus(targetId: targetId, expiryDate: expiry, thresholdDays: thresholdDays)
        else { return }
        if transition.shouldAlert, let days = transition.daysRemaining {
            await notifyIfEnabled(title: "Domain sắp hết hạn: \(target.name)", body: "Còn \(days) ngày", route: "/targets/\(targetId)")
        }
    }

    // MARK: - Report / history / system alerts

    private func maybeSendReport() async throws {
        let settings = try settingsRepo.load()
        guard settings.smtpEnabled, !settings.smtpRecipientEmail.isEmpty else { return }

        let period = SchedulerStateStore.reportPeriod(frequency: settings.smtpFrequency, dayOfWeek: settings.smtpDayOfWeek, dayOfMonth: settings.smtpDayOfMonth)
        guard period.isDueToday, try stateStore.lastReportSentPeriod() != period.periodIdentifier else { return }

        guard await reportSender.sendReport(label: period.label, days: period.days) else { return }
        try stateStore.markReportSent(period: period.periodIdentifier)
    }

    private func checkSystemAlerts() async {
        guard let statsProvider, let settings = try? settingsRepo.load() else { return }
        guard settings.systemTempAlertThresholdCelsius > 0 || settings.batteryLowAlertThresholdPercent > 0 else { return }

        let stats = await statsProvider.snapshotLight()

        if settings.systemTempAlertThresholdCelsius > 0, let temp = stats.cpuTempCelsius {
            let isHot = temp >= Double(settings.systemTempAlertThresholdCelsius)
            let wasActive = (try? stateStore.alertFlag("system_temp_alert_active")) ?? false
            if isHot && !wasActive {
                await notifyIfEnabled(title: "Nhiệt độ máy đang cao", body: "\(Int(temp))°C (ngưỡng \(settings.systemTempAlertThresholdCelsius)°C)", route: "/system")
                try? stateStore.setAlertFlag("system_temp_alert_active", true)
            } else if !isHot && wasActive {
                try? stateStore.setAlertFlag("system_temp_alert_active", false)
            }
        }

        if settings.batteryLowAlertThresholdPercent > 0, let percent = stats.batteryPercent {
            let charging = stats.batteryCharging ?? false
            let isLow = !charging && percent <= Double(settings.batteryLowAlertThresholdPercent)
            let wasActive = (try? stateStore.alertFlag("system_battery_alert_active")) ?? false
            if isLow && !wasActive {
                await notifyIfEnabled(title: "Pin yếu", body: "Còn \(Int(percent))% — hãy cắm sạc", route: "/system")
                try? stateStore.setAlertFlag("system_battery_alert_active", true)
            } else if (!isLow || charging) && wasActive {
                try? stateStore.setAlertFlag("system_battery_alert_active", false)
            }
        }
    }

    private func notifyIfEnabled(title: String, body: String, route: String?) async {
        guard (try? settingsRepo.load().notificationsEnabled) == true else { return }
        await notifier.notify(title: title, body: body, route: route)
    }
}
