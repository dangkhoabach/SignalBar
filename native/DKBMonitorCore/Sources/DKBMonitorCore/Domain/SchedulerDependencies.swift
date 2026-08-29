import Foundation

/// Implemented by the app target using `UNUserNotificationCenter` (Phase 6).
/// `route` is an app-internal path to navigate to if the user clicks through.
public protocol NotificationSending: Sendable {
    func notify(title: String, body: String, route: String?) async
}

/// Read-only hardware snapshot the scheduler needs for its two system-wide
/// alerts. Deliberately minimal — just the fields `Scheduler` actually reads,
/// not the full stats surface (CPU/RAM/disk/network/GPU) Phase 5 will expose
/// to the UI. Implemented by the app target via IOKit/`IOPowerSources`, which
/// can't live in this package (see D6 in the port plan: Core links no system
/// frameworks beyond Foundation/Security).
public struct SystemStatsSnapshot: Sendable, Equatable {
    public let cpuTempCelsius: Double?
    public let batteryPercent: Double?
    public let batteryCharging: Bool?

    public init(cpuTempCelsius: Double? = nil, batteryPercent: Double? = nil, batteryCharging: Bool? = nil) {
        self.cpuTempCelsius = cpuTempCelsius
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
    }
}

public protocol SystemStatsProviding: Sendable {
    func snapshot() async -> SystemStatsSnapshot
}

/// Implemented by the app target's mail module (Phase 9). Returns whether the
/// report was sent successfully — the scheduler only records the dedupe
/// period on success, matching `maybe_send_report`'s behavior.
public protocol ReportSending: Sendable {
    func sendReport(label: String, days: Int) async -> Bool
}
