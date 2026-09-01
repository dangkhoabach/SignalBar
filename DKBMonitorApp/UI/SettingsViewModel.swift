import DKBMonitorCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    static let shared = SettingsViewModel(
        repo: AppDatabase.shared.map { SettingsRepository(dbQueue: $0.dbQueue) }
    )

    private let repo: SettingsRepository?
    private var isLoaded = false

    var settings: AppSettings = .defaults {
        didSet {
            guard isLoaded, oldValue != settings else { return }
            try? repo?.update(settings)
        }
    }

    var isSendingTestEmail = false
    var testEmailResultMessage: String?

    init(repo: SettingsRepository?) {
        self.repo = repo
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        settings = (try? repo?.load()) ?? .defaults
        isLoaded = true
    }

    /// Ports the Tauri Settings page's "Send Test Email" action — lets the
    /// user confirm the relay + recipient work before waiting for a real
    /// scheduled report.
    func sendTestEmail() async {
        let recipient = settings.smtpRecipientEmail
        guard !recipient.isEmpty else { return }
        isSendingTestEmail = true
        let sent = await EmailReportSender.sendTestEmail(recipientEmail: recipient)
        isSendingTestEmail = false
        testEmailResultMessage = sent ? "Test email sent to \(recipient)." : "Failed to send test email."
    }
}
