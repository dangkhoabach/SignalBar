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
    static let shared: AppDatabase? = try? AppDatabase(path: AppDatabaseLocation.productionPath().path)
}
