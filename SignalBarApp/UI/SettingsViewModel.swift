import SignalBarCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    static let shared = SettingsViewModel(
        repo: AppDatabase.shared.map { SettingsRepository(dbQueue: $0.dbQueue) },
        sender: AppDatabase.shared.map { EmailReportSender(dbQueue: $0.dbQueue) },
        stateStore: AppDatabase.shared.map { SchedulerStateStore(dbQueue: $0.dbQueue) }
    )

    private let repo: SettingsRepository?
    /// Nil only when the database failed to open, the same condition `repo`
    /// already encodes — the startup alert covers that case, so every action
    /// here just no-ops rather than repeating the complaint.
    private let sender: EmailReportSender?
    private let stateStore: SchedulerStateStore?
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

    var isStartingVerification = false
    var isConfirmingVerification = false
    /// True once a code has been requested, which is what reveals the code
    /// field. Not persisted: a code expires in minutes, so carrying this
    /// across a relaunch would only offer a field that cannot work.
    var isAwaitingVerificationCode = false
    var verificationCode = ""
    /// Shown under the email field — the one place a failed verification is
    /// explained.
    var verificationMessage: String?

    /// The relay delivers only to the address this Mac verified, so an
    /// edited recipient is unverified again. Comparing the two is what makes
    /// that visible instead of reports quietly continuing to the old address.
    var isEmailVerified: Bool {
        !settings.smtpVerifiedEmail.isEmpty && settings.smtpVerifiedEmail == settings.smtpRecipientEmail
    }

    var isSendingTestWebhook = false
    var webhookTestResultMessage: String?
    /// Why the entered URL was rejected, shown under the field.
    var webhookURLProblem: String?

    /// What the scheduler last did on the user's behalf. Read whenever the
    /// page opens, not observed: both change in the background a few times a
    /// day at most, and a stale figure for the length of one visit is fine.
    var lastReportOutcome: SchedulerStateStore.ReportOutcome?
    var lastCleanupRun: SchedulerStateStore.CleanupRun?

    init(repo: SettingsRepository?, sender: EmailReportSender? = nil, stateStore: SchedulerStateStore? = nil) {
        self.repo = repo
        self.sender = sender
        self.stateStore = stateStore
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        settings = (try? repo?.load()) ?? .defaults
        isLoaded = true
        refreshLastRuns()
    }

    func refreshLastRuns() {
        lastReportOutcome = try? stateStore?.lastReportOutcome()
        lastCleanupRun = try? stateStore?.lastCleanupRun()
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
        guard let sender, isEmailVerified else { return }
        isSendingTestEmail = true
        let failure = await sender.sendTestEmail()
        isSendingTestEmail = false
        guard let failure else {
            testEmailResultMessage = "Test email sent to \(settings.smtpVerifiedEmail)."
            return
        }
        if failure == .notVerified {
            // The sender already dropped the token and the stored address;
            // mirroring it here is what makes the warning appear now rather
            // than after the next relaunch.
            settings.smtpVerifiedEmail = ""
        }
        testEmailResultMessage = failure.localizedDescription
    }

    // MARK: - Email verification

    /// Asks the relay to mail a code to the recipient address.
    ///
    /// The relay answers the same way whether or not it sent anything — it
    /// must not become a way to probe which addresses exist — so a success
    /// here means "accepted", not "delivered", and the message says so.
    func startEmailVerification() async {
        guard let sender else { return }
        let email = settings.smtpRecipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }

        isStartingVerification = true
        verificationMessage = nil
        let accepted = await sender.startVerification(email: email)
        isStartingVerification = false

        if accepted {
            isAwaitingVerificationCode = true
            verificationCode = ""
            verificationMessage = "If \(email) can receive mail, a code is on its way. It expires in 10 minutes."
        } else {
            verificationMessage = "Could not reach api.dangkhoabach.vn. Check your connection and try again."
        }
    }

    func confirmEmailVerification() async {
        guard let sender else { return }
        let email = settings.smtpRecipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !code.isEmpty else { return }

        isConfirmingVerification = true
        verificationMessage = nil
        do {
            try await sender.confirmVerification(email: email, code: code)
            // `confirmVerification` already wrote this through to the
            // database alongside the Keychain token; mirroring it here keeps
            // the on-screen state from lagging a relaunch behind.
            settings.smtpVerifiedEmail = email
            isAwaitingVerificationCode = false
            verificationCode = ""
        } catch {
            verificationMessage = error.localizedDescription
        }
        isConfirmingVerification = false
    }

    func forgetEmailVerification() {
        try? sender?.forgetVerification()
        settings.smtpVerifiedEmail = ""
        isAwaitingVerificationCode = false
        verificationCode = ""
        verificationMessage = nil
    }

    // MARK: - Webhook

    /// Checked as the user types rather than only when an alert eventually
    /// fires: a webhook is write-and-forget, so a URL that was never going
    /// to work would otherwise be discovered by an alert silently not
    /// arriving.
    func validateWebhookURL() async {
        let raw = settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            webhookURLProblem = nil
            return
        }
        // The field may have moved on while the DNS lookup was in flight.
        let problem = await AlertWebhook.validate(raw)
        guard raw == settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        webhookURLProblem = problem?.message
    }

    func sendTestWebhook() async {
        let raw = settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else { return }
        if let problem = await AlertWebhook.validate(raw) {
            webhookURLProblem = problem.message
            webhookTestResultMessage = nil
            return
        }

        isSendingTestWebhook = true
        let delivered = await WebhookAlertSender.post(
            to: url,
            title: "SignalBar test alert",
            body: "If you can read this, alerts will reach here.",
            route: nil
        )
        isSendingTestWebhook = false
        webhookTestResultMessage = delivered
            ? "Delivered to \(WebhookDestination.forURL(url).displayName)."
            : "The endpoint didn't accept it. Check the URL is still valid and hasn't been revoked."
    }
}

extension WebhookDestination {
    var displayName: String {
        switch self {
        case .slack: "Slack"
        case .discord: "Discord"
        case .generic: "your webhook"
        }
    }
}
