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
    private var saveTask: Task<Void, Never>?

    var settings: AppSettings = .defaults {
        didSet {
            guard isLoaded, oldValue != settings else { return }
            scheduleSave()
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

    /// Coalesces rapid-fire changes (a Stepper tick, or typing into the
    /// recipient-email field) into a single SQLite write ~500ms after the
    /// user stops, instead of writing the full `app_settings` row on the
    /// main thread for every single keystroke/tick.
    private func scheduleSave() {
        saveTask?.cancel()
        let toSave = settings
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            try? self?.repo?.update(toSave)
        }
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
