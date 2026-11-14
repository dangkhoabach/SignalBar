import SignalBarCore

/// The single `NetworkMonitor` for the app's lifetime, started from
/// `AppDelegate` beside the domain `Scheduler`.
@MainActor
enum AppNetworkMonitor {
    static let shared: NetworkMonitor? = AppDatabase.shared.map { db in
        NetworkMonitor(dbQueue: db.dbQueue, notifier: NotificationManager.shared, alertText: LocalizedAlertText())
    }
}
