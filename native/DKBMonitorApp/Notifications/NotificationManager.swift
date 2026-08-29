import AppKit
import DKBMonitorCore
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
/// hit in the Phase 0 PoC's `NotificationManager`.
@MainActor
public final class NotificationManager: NSObject, NotificationSending, @unchecked Sendable {
    public static let shared = NotificationManager()

    /// Set by whichever phase wires up real navigation (Phase 11/12). Until
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
        let viewDetails = UNNotificationAction(identifier: Self.viewDetailsActionIdentifier, title: "Xem chi tiết", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [viewDetails], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// The real, current permission state — the old app's limitation being
    /// fixed here (see Phase 6 plan note) was that it always reported
    /// "Granted" regardless of what the user actually chose.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Only call this at the moment the user actually opts in (flipping the
    /// Settings toggle — Phase 12), never at app launch, so the permission
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
            NSApp.setActivationPolicy(.regular)
            for window in NSApp.windows { window.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
            if let route {
                NotificationManager.shared.onRouteSelected?(route)
            }
        }
        completionHandler()
    }
}
