import DKBMonitorCore

/// One shared connection for the whole app's lifetime, instead of every
/// view model opening its own separate `AppDatabase(path:)` to the same
/// file.
///
/// This matters beyond just avoiding redundant connections: GRDB's
/// `ValueObservation` only re-fires for writes made through the *same*
/// `DatabaseQueue` instance it was created from — it does not detect
/// changes committed via a different connection to the same SQLite file.
/// With separate connections per view model, `Scheduler`'s writes (via
/// `AppScheduler`'s own connection) never triggered `OverviewViewModel`'s
/// `observeOverview()` (its own, different connection) — the Overview list
/// silently went stale until the app restarted. Routing everything through
/// this one shared `AppDatabase` fixes that at the root.
extension AppDatabase {
    /// Opened once, and the failure kept rather than thrown away.
    ///
    /// Every view model and the scheduler alike reach the database through
    /// `shared`, and each of them degrades to a quiet no-op when it's `nil`.
    /// That combination meant a database that wouldn't open — corrupt file,
    /// a migration that failed, a disk with no room — produced an app that
    /// launched looking perfectly healthy, showed an empty domain list,
    /// silently refused to save settings, and monitored nothing at all.
    /// Keeping the error is what lets the app say so on launch.
    private static let opened = Result { try AppDatabase(path: AppDatabaseLocation.productionPath().path) }

    static var shared: AppDatabase? { try? opened.get() }

    /// The reason the database couldn't be opened, if it couldn't.
    static var openFailure: Error? {
        if case .failure(let error) = opened { return error }
        return nil
    }
}
