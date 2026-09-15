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
    /// The edit waiting out the debounce in `scheduleSave`, if any.
    private var pendingSave: AppSettings?

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
        pendingSave = toSave
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            try? self?.repo?.update(toSave)
            self?.pendingSave = nil
        }
    }

    /// Writes a debounced edit immediately.
    ///
    /// Quitting cancels the pending `saveTask` along with everything else, so
    /// changing a setting and pressing Cmd+Q inside the same half-second lost
    /// the change with no hint that anything had gone unsaved. Called from
    /// `applicationWillTerminate`, which is the last point that still runs on
    /// the main thread with the database open.
    func flushPendingSave() {
        guard let pending = pendingSave else { return }
        saveTask?.cancel()
        saveTask = nil
        pendingSave = nil
        try? repo?.update(pending)
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
