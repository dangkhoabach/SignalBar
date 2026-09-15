import DKBMonitorCore

/// The single running `Scheduler` instance for the app's lifetime — started
/// from `AppDelegate.applicationDidFinishLaunching`. Also the entry point
/// the Overview UI calls into for "Check Now"/"Check All Now" (Phase 11).
///
/// `@MainActor`: constructing it touches `NotificationManager.shared`, which
/// is main-actor-isolated.
@MainActor
enum AppScheduler {
    static let shared: Scheduler? = AppDatabase.shared.map { db in
        Scheduler(
            dbQueue: db.dbQueue,
            notifier: NotificationManager.shared,
            reportSender: EmailReportSender(dbQueue: db.dbQueue),
            statsProvider: SystemStatsService(),
            cleanupRunner: ScheduledCleanupRunner(service: JunkCleanerService())
        )
    }
}
