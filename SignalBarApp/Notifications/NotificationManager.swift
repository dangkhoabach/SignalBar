import AppKit
import SignalBarCore
import UserNotifications

/// Native `UNUserNotificationCenter` notifications with click-through
/// support — replaces `notification.rs`'s `notify-rust` + dedicated-OS-thread
/// workaround (that existed only to get a click callback out of the legacy
/// NSUserNotificationCenter backend; `UNUserNotificationCenter`'s delegate
/// gives that natively).
///
/// `@MainActor`-isolated because everything it touches after a click
/// (`NSApp`, windows, `onRouteSelected`) must run on the main thread; the two
/// `UNUserNotificationCenterDelegate` methods are `nonisolated` because the
/// system calls them on an arbitrary thread (a hard requirement of the
/// `@objc` delegate protocol), and immediately hop back via `Task { @MainActor
/// in ... }` — extracting only the `Sendable` primitives (action identifier,
/// route string) first, the same "avoid `sending` data-race errors" pattern
/// first hit in a proof of concept's `NotificationManager`.
@MainActor
public final class NotificationManager: NSObject, NotificationSending, @unchecked Sendable {
    public static let shared = NotificationManager()

    /// Set by whatever wires up real navigation. Until
    /// then, a click-through still brings the app forward — it just has
    /// nowhere in-app to navigate to yet.
    public var onRouteSelected: ((String) -> Void)?

    // `nonisolated`: read from the two nonisolated delegate methods below,
    // which the system calls off the main actor.
    nonisolated private static let categoryIdentifier = "DKB_MONITOR_ALERT"
    nonisolated private static let viewDetailsActionIdentifier = "VIEW_DETAILS"
    nonisolated private static let routeUserInfoKey = "route"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let viewDetails = UNNotificationAction(identifier: Self.viewDetailsActionIdentifier, title: String(localized: "View Details"), options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [viewDetails], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// The real, current permission state — the old app's limitation being
    /// fixed here was that it always reported
    /// "Granted" regardless of what the user actually chose.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Only call this at the moment the user actually opts in (flipping the
    /// Settings toggle), never at app launch, so the permission
    /// prompt has context instead of appearing out of nowhere.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(title: String, body: String, route: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        if let route {
            content.userInfo = [Self.routeUserInfoKey: route]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Deep-links to System Settings' Notifications pane, for a "Manage in
    /// System Settings" affordance next to the in-app toggle.
    public static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Shows the banner even while the app is frontmost — otherwise
    /// foreground-delivered notifications are silently suppressed by default.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let route = response.notification.request.content.userInfo[NotificationManager.routeUserInfoKey] as? String

        guard actionIdentifier == UNNotificationDefaultActionIdentifier || actionIdentifier == NotificationManager.viewDetailsActionIdentifier else {
            completionHandler()
            return
        }

        Task { @MainActor in
            WindowPresenter.showMainWindow()
            if let route {
                NotificationManager.shared.onRouteSelected?(route)
            }
        }
        completionHandler()
    }
}

/// The scheduler's alerts in the language picked in Settings, for both the
/// notification and the webhook post. Core only knows the English text.
struct LocalizedAlertText: AlertTextLocalizing {
    func text(for message: AlertMessage) -> (title: String, body: String) {
        // English is the source language and has no table of its own.
        guard AppLocale.selected != .en else { return EnglishAlertText().text(for: message) }
        let bundle = AppLocale.bundle
        switch message {
        case .targetDown(let name, let error):
            return (String(localized: "\(name) is down", bundle: bundle),
                    error ?? String(localized: "The health check failed", bundle: bundle))
        case .targetBackUp(let name):
            return (String(localized: "\(name) is back up", bundle: bundle),
                    String(localized: "The health check passed", bundle: bundle))
        case .targetSlow(let name, let responseMs, let thresholdMs):
            return (String(localized: "\(name) is responding slowly", bundle: bundle),
                    String(localized: "\(responseMs)ms (threshold \(thresholdMs)ms)", bundle: bundle))
        case .targetResponseNormal(let name):
            return (String(localized: "\(name) is responding normally again", bundle: bundle),
                    String(localized: "The response time is back to normal", bundle: bundle))
        case .sslExpiring(let name, let daysLeft):
            return (String(localized: "SSL certificate expires soon: \(name)", bundle: bundle),
                    String(localized: "\(daysLeft) days left", bundle: bundle))
        case .domainExpiring(let name, let daysLeft):
            return (String(localized: "Domain expires soon: \(name)", bundle: bundle),
                    String(localized: "\(daysLeft) days left", bundle: bundle))
        case .cleanupFinished(let freed, let locations, let skipped):
            var body = String(localized: "Moved \(freed) to the Trash from \(locations) locations.", bundle: bundle)
            if !skipped.isEmpty {
                body += " " + String(localized: "Not fully cleared: \(skipped.joined(separator: ", ")).", bundle: bundle)
            }
            return (String(localized: "Scheduled cleanup finished", bundle: bundle), body)
        case .systemHot(let celsius, let thresholdCelsius):
            return (String(localized: "Your Mac is running hot", bundle: bundle),
                    String(localized: "\(celsius)°C (threshold \(thresholdCelsius)°C)", bundle: bundle))
        case .batteryLow(let percent):
            return (String(localized: "Battery low", bundle: bundle),
                    String(localized: "\(percent)% left — plug in the charger", bundle: bundle))
        case .remoteResourceHigh(let server, let resource, let percent, let thresholdPercent):
            let label = resource == .disk ? String(localized: "Disk", bundle: bundle) : resource.label
            return (String(localized: "\(server): \(label) is high", bundle: bundle),
                    String(localized: "\(percent)% (threshold \(thresholdPercent)%)", bundle: bundle))
        }
    }
}
