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
    /// `percent` comes from `RemoteResourceAlerts.wholePercent`.
    case remoteResourceHigh(server: String, resource: RemoteResource, percent: Int, thresholdPercent: Int)
    /// `address` is the IP, followed by the manufacturer when one is known.
    case networkNewDevice(name: String, address: String)
    case networkDeviceOffline(name: String, address: String)
    case networkDeviceBackOnline(name: String, address: String)
    /// `devices` names the devices taking turns on the address.
    case networkIPConflict(address: String, devices: String)
    case networkSourceFailing(source: String, error: String)
    case networkSourceRecovered(source: String)
    /// `holder` names the network the new address belongs to, when known.
    case publicIPChanged(old: String, new: String, holder: String?)
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
        case .remoteResourceHigh(let server, let resource, let percent, let thresholdPercent):
            ("\(server): \(resource.label) is high", "\(percent)% (threshold \(thresholdPercent)%)")
        case .networkNewDevice(let name, let address):
            ("New device on the network: \(name)", address)
        case .networkDeviceOffline(let name, let address):
            ("\(name) left the network", address)
        case .networkDeviceBackOnline(let name, let address):
            ("\(name) is back on the network", address)
        case .networkIPConflict(let address, let devices):
            ("IP conflict on \(address)", devices)
        case .networkSourceFailing(let source, let error):
            ("Can't read \(source)", error)
        case .networkSourceRecovered(let source):
            ("\(source) can be read again", "Network data from it is up to date")
        case .publicIPChanged(let old, let new, let holder):
            ("Public IP changed to \(new)", ["Was \(old)", holder].compactMap { $0 }.joined(separator: " · "))
        }
    }
}
