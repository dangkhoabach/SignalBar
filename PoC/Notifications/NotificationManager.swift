import Foundation
import UserNotifications
import AppKit

/// PoC: confirms UNUserNotificationCenter reports real permission state
/// (unlike notify-rust's macOS backend, which always claimed "Granted"),
/// and that clicking a notification's action button is caught while the app
/// has no visible window (simulates the tray-only background state).
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var authorizationStatus: String = "unknown"
    @Published var lastClickResult: String = "(none yet)"

    private let category = "POC_CATEGORY"
    private let actionID = "POC_DEFAULT_ACTION"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let action = UNNotificationAction(identifier: actionID, title: "Xem chi tiết", options: [])
        let cat = UNNotificationCategory(identifier: category, actions: [action], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        refreshStatus()
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.authorizationStatus = String(describing: status)
            }
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.authorizationStatus = granted ? "authorized" : "denied (\(error?.localizedDescription ?? "no reason given"))"
            }
        }
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "DKB Monitor PoC"
        content.body = "Click này (hoặc nút action) để xác nhận click-through hoạt động."
        content.categoryIdentifier = category
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in self.lastClickResult = "Send failed: \(error.localizedDescription)" }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            self.lastClickResult = "Clicked at \(Date()), actionIdentifier=\(actionID)"
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    /// Lets a notification arrive while the app has no key window, to mimic
    /// the "hidden in tray" state the real app spends most of its time in.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
