import Foundation
import GRDB
import Testing
@testable import SignalBarCore

@Suite struct SchedulerStateStoreTests {
    private func makeStore() throws -> SchedulerStateStore {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return SchedulerStateStore(dbQueue: app.dbQueue)
    }

    @Test func alertFlagRoundTrips() throws {
        let store = try makeStore()
        #expect(try store.alertFlag("system_temp_alert_active") == false)
        try store.setAlertFlag("system_temp_alert_active", true)
        #expect(try store.alertFlag("system_temp_alert_active") == true)
        try store.setAlertFlag("system_temp_alert_active", false)
        #expect(try store.alertFlag("system_temp_alert_active") == false)
    }

    @Test func cleanupIsNoOpWhenRetentionDisabled() throws {
        let store = try makeStore()
        try store.cleanupHistoryIfDue(retentionDays: 0)
        // No crash / no-op is the whole point here; nothing else to assert
        // without a target+check_results fixture.
    }

    @Test func cleanupRunsOnceThenSkipsSameDay() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let store = SchedulerStateStore(dbQueue: app.dbQueue)
        let repo = TargetRepository(dbQueue: app.dbQueue)
        let target = try repo.add(NewTargetInput(name: "A", url: "https://a.com"))

        try app.dbQueue.write { db in
            var old = CheckResult(targetId: target.id!, checkedAt: Date(timeIntervalSinceNow: -200 * 86400), success: true)
            try old.insert(db)
            var recent = CheckResult(targetId: target.id!, checkedAt: Date(), success: true)
            try recent.insert(db)
        }

        try store.cleanupHistoryIfDue(retentionDays: 90)
        let remaining = try app.dbQueue.read { db in try CheckResult.fetchCount(db) }
        #expect(remaining == 1)

        // Second call same day: guarded, must not touch anything further
        // (nothing left old enough to delete anyway, but this also proves
        // the guard doesn't throw/misbehave on a second same-day call).
        try store.cleanupHistoryIfDue(retentionDays: 90)
        let stillRemaining = try app.dbQueue.read { db in try CheckResult.fetchCount(db) }
        #expect(stillRemaining == 1)
    }

    @Test func dailyReportIsAlwaysDue() {
        let period = SchedulerStateStore.reportPeriod(frequency: "daily", dayOfWeek: 1, dayOfMonth: 1)
        #expect(period.isDueToday)
        #expect(period.label == "Daily")
        #expect(period.days == 1)
    }

    @Test func weeklyReportIsDueOnlyOnConfiguredWeekday() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let todayFromMonday = (weekday + 5) % 7

        let matching = SchedulerStateStore.reportPeriod(frequency: "weekly", dayOfWeek: todayFromMonday, dayOfMonth: 1, now: today)
        #expect(matching.isDueToday)

        let nonMatching = SchedulerStateStore.reportPeriod(frequency: "weekly", dayOfWeek: (todayFromMonday + 1) % 7, dayOfMonth: 1, now: today)
        #expect(!nonMatching.isDueToday)
    }

    @Test func monthlyReportIsDueOnlyOnConfiguredDay() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date()
        let dayOfMonth = calendar.component(.day, from: today)

        let matching = SchedulerStateStore.reportPeriod(frequency: "monthly", dayOfWeek: 0, dayOfMonth: dayOfMonth, now: today)
        #expect(matching.isDueToday)

        let nonMatching = SchedulerStateStore.reportPeriod(frequency: "monthly", dayOfWeek: 0, dayOfMonth: dayOfMonth == 1 ? 2 : 1, now: today)
        #expect(!nonMatching.isDueToday)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    /// The monthly window was a flat 30 days regardless of the month, so the
    /// report headed "last 30 days" quietly missed a day of a 31-day month
    /// and covered three days twice after February.
    @Test func theMonthlyWindowMatchesTheMonthThatJustEnded() throws {
        // 1 Mar back to 1 Feb is 28 days in a common year.
        let march = SchedulerStateStore.reportPeriod(
            frequency: "monthly", dayOfWeek: 0, dayOfMonth: 1, now: try utcDate(2026, 3, 1)
        )
        #expect(march.days == 28)

        // 1 May back to 1 Apr is 30.
        let may = SchedulerStateStore.reportPeriod(
            frequency: "monthly", dayOfWeek: 0, dayOfMonth: 1, now: try utcDate(2026, 5, 1)
        )
        #expect(may.days == 30)

        // 1 Jun back to 1 May is 31.
        let june = SchedulerStateStore.reportPeriod(
            frequency: "monthly", dayOfWeek: 0, dayOfMonth: 1, now: try utcDate(2026, 6, 1)
        )
        #expect(june.days == 31)
    }

    /// A leap February is 29, not 28 — the whole point of deriving this from
    /// the calendar rather than a constant.
    @Test func theMonthlyWindowHandlesALeapFebruary() throws {
        let march2028 = SchedulerStateStore.reportPeriod(
            frequency: "monthly", dayOfWeek: 0, dayOfMonth: 1, now: try utcDate(2028, 3, 1)
        )
        #expect(march2028.days == 29)
    }

    /// Daily and weekly windows are fixed by definition and must not move.
    @Test func dailyAndWeeklyWindowsAreUnchanged() {
        #expect(SchedulerStateStore.reportPeriod(frequency: "daily", dayOfWeek: 0, dayOfMonth: 1).days == 1)
        #expect(SchedulerStateStore.reportPeriod(frequency: "weekly", dayOfWeek: 0, dayOfMonth: 1).days == 7)
    }
}
