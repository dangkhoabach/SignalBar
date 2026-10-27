import Foundation

/// Every alert the scheduler sends, as data rather than text. The app turns
/// it into a title and body in the language picked in Settings
/// (`AlertTextLocalizing`); Core has no string catalog of its own, so it
/// only knows the English text (`EnglishAlertText`).
public enum AlertMessage: Sendable, Equatable {
    case targetDown(name: String, error: String?)
    case targetBackUp(name: String)
    case targetSlow(name: String, responseMs: Int, thresholdMs: Int)
    case targetResponseNormal(name: String)
    case sslExpiring(name: String, daysLeft: Int)
    case domainExpiring(name: String, daysLeft: Int)
    /// `freed` is already formatted (`ByteCountFormatter`).
    case cleanupFinished(freed: String, locations: Int, skipped: [String])
    case systemHot(celsius: Int, thresholdCelsius: Int)
    case batteryLow(percent: Int)
    /// `percent` comes from `RemoteResourceAlerts.wholePercent`.
    case remoteResourceHigh(server: String, resource: RemoteResource, percent: Int, thresholdPercent: Int)
}

/// Turns an alert into the title and body of a notification and of a
/// webhook post.
public protocol AlertTextLocalizing: Sendable {
    func text(for message: AlertMessage) -> (title: String, body: String)
}

/// The English text, used wherever the host injects nothing else (tests).
public struct EnglishAlertText: AlertTextLocalizing {
    public init() {}

    public func text(for message: AlertMessage) -> (title: String, body: String) {
        switch message {
        case .targetDown(let name, let error):
            ("\(name) is down", error ?? "The health check failed")
        case .targetBackUp(let name):
            ("\(name) is back up", "The health check passed")
        case .targetSlow(let name, let responseMs, let thresholdMs):
            ("\(name) is responding slowly", "\(responseMs)ms (threshold \(thresholdMs)ms)")
        case .targetResponseNormal(let name):
            ("\(name) is responding normally again", "The response time is back to normal")
        case .sslExpiring(let name, let daysLeft):
            ("SSL certificate expires soon: \(name)", "\(daysLeft) days left")
        case .domainExpiring(let name, let daysLeft):
            ("Domain expires soon: \(name)", "\(daysLeft) days left")
        case .cleanupFinished(let freed, let locations, let skipped):
            ("Scheduled cleanup finished",
             "Moved \(freed) to the Trash from \(locations) locations."
                + (skipped.isEmpty ? "" : " Not fully cleared: \(skipped.joined(separator: ", ")).")
            )
        case .systemHot(let celsius, let thresholdCelsius):
            ("Your Mac is running hot", "\(celsius)°C (threshold \(thresholdCelsius)°C)")
        case .batteryLow(let percent):
            ("Battery low", "\(percent)% left — plug in the charger")
        case .remoteResourceHigh(let server, let resource, let percent, let thresholdPercent):
            ("\(server): \(resource.label) is high", "\(percent)% (threshold \(thresholdPercent)%)")
        }
    }
}
