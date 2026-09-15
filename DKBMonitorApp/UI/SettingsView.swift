import DKBMonitorCore
import SwiftUI

/// The app's unified Settings tab (sidebar + app menu Cmd+, + menu bar both
/// route here, see `WindowPresenter.showSettings()`).
///
/// Restyled to match DKB-Downloader's `SettingsView` (`native/
/// DKBDownloaderApp/UI/Settings/SettingsView.swift`): a single `Form` with
/// `.formStyle(.grouped)` and one `Section` per topic, segmented `Picker`s
/// for small either/or choices (Theme, Language), rather than this page's
/// earlier `GroupBox` card layout — the goal is visual consistency across
/// the user's own apps' Settings pages, not matching this app's own
/// System/Domains tabs.
///
/// The Language picker actually works, unlike a naive first attempt would:
/// Downloader's own build notes (`Localization.swift`) record that
/// `String(localized:locale:)` silently ignores the explicit `locale:`
/// argument in SwiftUI, which is why that app resorted to a hand-rolled
/// `t()`/`.lproj`-bundle lookup. This app's views build `Text`/`Label` from
/// `LocalizedStringKey` almost everywhere, though — and `LocalizedStringKey`
/// resolution *does* correctly follow whatever `Locale` sits in the
/// environment, so overriding `\.locale` on the app's root views
/// (`DKBMonitorApp.swift`) is the reliable fix here, no custom lookup helper
/// needed.
struct SettingsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    @Bindable private var overviewViewModel = OverviewViewModel.shared
    @AppStorage("themePreference") private var themePreferenceRaw = ThemePreference.system.rawValue
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    @AppStorage("showCPUPercentInMenuBar") private var showCPUPercentInMenuBar = false
    /// Set when macOS refuses notifications while the in-app toggle is on —
    /// the state in which alerts are configured but can never be delivered.
    @State private var notificationsBlocked = false
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    /// Registered, but macOS is holding it until the user approves it in
    /// System Settings — on, yet not actually launching at login.
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?
    @State private var isPresentingClearAllConfirm = false
    /// Mirrors Sparkle's own preference for display only — the write goes
    /// straight back to Sparkle, and `.task` re-reads it, so this never
    /// becomes a second source of truth.
    @State private var automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themePreferenceRaw) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Language", selection: Binding(
                    get: { AppLocale(rawValue: languageRaw) ?? .systemDefault },
                    set: { languageRaw = $0.rawValue }
                )) {
                    Text("VI").tag(AppLocale.vi)
                    Text("EN").tag(AppLocale.en)
                }
                .pickerStyle(.segmented)

                Toggle("Show CPU % in menu bar", isOn: $showCPUPercentInMenuBar)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { setLoginItemEnabled($0) }
                ))
                if loginItemNeedsApproval {
                    Label(
                        "Waiting for your approval in System Settings › General › Login Items. Until then DKB Monitor won't start at login.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Toggle("Enable Notifications", isOn: Binding(
                    get: { viewModel.settings.notificationsEnabled },
                    set: { newValue in
                        viewModel.settings.notificationsEnabled = newValue
                        guard newValue else {
                            notificationsBlocked = false
                            return
                        }
                        Task {
                            // The answer was being discarded, so a denial left
                            // the toggle on and every later alert silently
                            // going nowhere — the one failure this app can't
                            // afford, since an alert that never arrives looks
                            // exactly like nothing being wrong.
                            //
                            // `false` covers a fresh denial and an earlier one
                            // alike: once denied, macOS stops showing the
                            // prompt and just answers no.
                            guard await NotificationManager.shared.requestAuthorization() else {
                                notificationsBlocked = true
                                viewModel.settings.notificationsEnabled = false
                                return
                            }
                            notificationsBlocked = false
                            // Fires a real notification on enable, same
                            // as the old Tauri app's
                            // handleNotificationsToggle — this is also
                            // what actually triggers the first-use
                            // macOS permission prompt.
                            await NotificationManager.shared.notify(
                                title: "DKB Monitor",
                                body: "Notifications are enabled.",
                                route: nil
                            )
                        }
                    }
                ))
                if notificationsBlocked {
                    Label(
                        "macOS is blocking notifications for DKB Monitor, so alerts would never arrive. Allow them in System Settings, then turn this back on.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text("Get notified when a domain goes down or an SSL/domain expiry is approaching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Manage in System Settings…") {
                    NotificationManager.openSystemNotificationSettings()
                }
            }

            Section("Health Checks") {
                Picker("Default check interval", selection: $viewModel.settings.httpCheckIntervalSecs) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                    Text("1 hour").tag(3600)
                }
                Text("How often a newly added domain is re-checked. Existing domains keep their own interval, editable per domain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledStepper("Failure alert threshold", value: $viewModel.settings.failureAlertThreshold, in: 1...20, suffix: "checks")
                labeledStepper(
                    "Slow response threshold",
                    value: $viewModel.settings.responseTimeAlertThresholdMs, in: 0...30000, step: 500,
                    suffix: "ms", zeroMeans: "off"
                )
            }

            Section("Expiry") {
                labeledStepper("SSL alert", value: $viewModel.settings.sslAlertThresholdDays, in: 1...90, suffix: "days before")
                labeledStepper("Domain alert", value: $viewModel.settings.domainAlertThresholdDays, in: 1...90, suffix: "days before")
            }

            Section("System") {
                labeledStepper(
                    "High temperature alert",
                    value: $viewModel.settings.systemTempAlertThresholdCelsius, in: 0...100,
                    suffix: "°C", zeroMeans: "off"
                )
                labeledStepper(
                    "Low battery alert",
                    value: $viewModel.settings.batteryLowAlertThresholdPercent, in: 0...100,
                    suffix: "%", zeroMeans: "off"
                )
            }

            Section("Remote Servers") {
                // Thresholds are global; which servers are watched is set
                // per server, in that server's own form. Neither alone does
                // anything — a threshold with no watched server is silent,
                // and a watched server with no threshold is never polled.
                Text("Applies to servers you've switched Monitoring on for. Each is checked every few minutes over SSH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                labeledStepper(
                    "CPU alert",
                    value: $viewModel.settings.remoteCPUAlertThresholdPercent, in: 0...100, step: 5,
                    suffix: "%", zeroMeans: "off"
                )
                labeledStepper(
                    "RAM alert",
                    value: $viewModel.settings.remoteMemoryAlertThresholdPercent, in: 0...100, step: 5,
                    suffix: "%", zeroMeans: "off"
                )
                labeledStepper(
                    "Disk alert",
                    value: $viewModel.settings.remoteDiskAlertThresholdPercent, in: 0...100, step: 5,
                    suffix: "%", zeroMeans: "off"
                )
            }

            Section("History") {
                labeledStepper(
                    "Retention",
                    value: $viewModel.settings.historyRetentionDays, in: 0...365, step: 5,
                    suffix: "days", zeroMeans: "forever"
                )
            }

            Section("Email Report") {
                Toggle("Enable Email Reports", isOn: $viewModel.settings.smtpEnabled)
                if viewModel.settings.smtpEnabled {
                    // The app holds no mail credential of its own, so reports
                    // are posted to a relay — which means the recipient
                    // address and the name of every monitored domain leave
                    // this Mac. That is worth saying on the page where it is
                    // switched on, not only in the source.
                    Text("Reports are sent through admin.dangkhoabach.vn. The recipient address and your domain names are sent to that server so it can deliver the mail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Recipient Email", text: $viewModel.settings.smtpRecipientEmail, prompt: Text("you@example.com"))
                    emailVerification
                    Picker("Frequency", selection: $viewModel.settings.smtpFrequency) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                    }
                    if viewModel.settings.smtpFrequency == "weekly" {
                        // `smtpDayOfWeek` is days-from-Monday (0...6), matching
                        // `SchedulerStateStore.reportPeriod`'s convention.
                        Picker("Day of Week", selection: $viewModel.settings.smtpDayOfWeek) {
                            ForEach(0..<7, id: \.self) { daysFromMonday in
                                Text(Calendar.current.weekdaySymbols[(daysFromMonday + 1) % 7]).tag(daysFromMonday)
                            }
                        }
                    } else if viewModel.settings.smtpFrequency == "monthly" {
                        Stepper("Day of Month: \(viewModel.settings.smtpDayOfMonth)", value: $viewModel.settings.smtpDayOfMonth, in: 1...28)
                    }
                    HStack {
                        Spacer()
                        if viewModel.isSendingTestEmail {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Send Test Email") { Task { await viewModel.sendTestEmail() } }
                                .disabled(!viewModel.isEmailVerified)
                        }
                    }
                }
            }

            Section("Scheduled Cleanup") {
                Toggle("Clean selected locations on a schedule", isOn: $viewModel.settings.cleanupScheduleEnabled)
                if viewModel.settings.cleanupScheduleEnabled {
                    // Said plainly at the switch, not buried: this is the one
                    // setting in the app that deletes the user's files while
                    // they are not looking.
                    Text("Everything is moved to the Trash, never deleted outright, and you get a notification when a run finishes. The Trash itself can't be emptied on a schedule.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Frequency", selection: $viewModel.settings.cleanupFrequency) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                    }
                    if viewModel.settings.cleanupFrequency == "weekly" {
                        Picker("Day of Week", selection: $viewModel.settings.cleanupDayOfWeek) {
                            ForEach(0..<7, id: \.self) { daysFromMonday in
                                Text(Calendar.current.weekdaySymbols[(daysFromMonday + 1) % 7]).tag(daysFromMonday)
                            }
                        }
                    }
                    cleanupTargetPicker
                }
            }

            Section("Webhook Alerts") {
                Toggle("Send alerts to a webhook", isOn: $viewModel.settings.webhookEnabled)
                if viewModel.settings.webhookEnabled {
                    // Separate from "Enable Notifications" on purpose: the
                    // point of a webhook is reaching a channel when nobody
                    // is at this Mac, so switching off local notifications
                    // must not switch this off too.
                    Text("Every alert also goes to this URL. Slack and Discord webhook URLs are recognised automatically; anything else receives plain JSON. Sent straight from this Mac — no relay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Webhook URL",
                        text: $viewModel.settings.webhookURL,
                        prompt: Text("https://hooks.slack.com/services/…")
                    )
                    .task(id: viewModel.settings.webhookURL) {
                        await viewModel.validateWebhookURL()
                    }
                    if let problem = viewModel.webhookURLProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        if let result = viewModel.webhookTestResultMessage {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.isSendingTestWebhook {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Send Test Alert") { Task { await viewModel.sendTestWebhook() } }
                                .disabled(viewModel.settings.webhookURL.isEmpty || viewModel.webhookURLProblem != nil)
                        }
                    }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { automaticUpdateChecks },
                    set: {
                        automaticUpdateChecks = $0
                        AppUpdater.automaticallyChecksForUpdates = $0
                    }
                ))
                Text("Checks updates.dangkhoabach.vn once a day. Turning this off means updates only happen when you ask for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Check Now") { AppUpdater.checkForUpdates() }
                }
            }

            // Ported from the old Tauri app's `AlertsDataSettingsPage`
            // "Domains" card — Export/Import already existed in the
            // Overview toolbar's menu, but "Clear All Domains" had no
            // equivalent anywhere in the native app yet.
            Section("Data") {
                Text("Export, import, or wipe your monitored domains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export Domains…") { overviewViewModel.exportTargets() }
                    Button("Import Domains…") { overviewViewModel.importTargets() }
                    Spacer()
                    Button("Clear All Domains", role: .destructive) { isPresentingClearAllConfirm = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.loadIfNeeded() }
        .task {
            // Both of these live outside the app, and both were only ever
            // read once. The user can revoke notifications or remove the
            // login item from System Settings at any point, which left the
            // toggles here showing a state that stopped being true. Re-read
            // whenever this page opens rather than trusting the last value.
            loginItemEnabled = LoginItemManager.shared.isEnabled
            loginItemNeedsApproval = LoginItemManager.shared.requiresApproval
            // Sparkle's own first-launch prompt can answer this before
            // Settings is ever opened, and its Check for Updates sheet can
            // change it too.
            automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates

            guard viewModel.settings.notificationsEnabled else { return }
            notificationsBlocked = await NotificationManager.shared.authorizationStatus() == .denied
        }
        .alert("Login Item Error", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK", role: .cancel) { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
        .alert("Test Email", isPresented: Binding(
            get: { viewModel.testEmailResultMessage != nil },
            set: { if !$0 { viewModel.testEmailResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.testEmailResultMessage = nil }
        } message: {
            Text(viewModel.testEmailResultMessage ?? "")
        }
        .confirmationDialog(
            "Clear All Domains?",
            isPresented: $isPresentingClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All Domains", role: .destructive) { overviewViewModel.clearAllTargets() }
        } message: {
            Text("This permanently deletes every monitored domain and its history. This cannot be undone.")
        }
    }

    /// Only Trash-safe locations are listed. The Trash target is excluded by
    /// `isEligibleForScheduledCleaning` rather than filtered out by name here,
    /// so this list and what the scheduler will actually touch cannot drift
    /// apart.
    @ViewBuilder
    private var cleanupTargetPicker: some View {
        let selected = Set(viewModel.settings.cleanupTargetPaths.split(separator: "\n").map(String.init))
        let available = JunkTarget.defaults(homeDirectory: NSHomeDirectory())
            .filter(\.isEligibleForScheduledCleaning)

        VStack(alignment: .leading, spacing: 4) {
            Text("Locations").font(.subheadline.weight(.medium))
            ForEach(available) { target in
                Toggle(isOn: Binding(
                    get: { selected.contains(target.path) },
                    set: { isOn in
                        var paths = selected
                        if isOn { paths.insert(target.path) } else { paths.remove(target.path) }
                        viewModel.settings.cleanupTargetPaths = paths.sorted().joined(separator: "\n")
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.name)
                        Text(target.displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if selected.isEmpty {
                Label("No location selected — nothing will be cleaned.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The relay refuses to deliver anywhere this Mac has not proved it can
    /// read, so an address that looks filled in is not yet an address that
    /// receives anything. This is the only place that difference is visible,
    /// which is why the unverified state is a warning rather than a caption.
    @ViewBuilder
    private var emailVerification: some View {
        if viewModel.isEmailVerified {
            HStack {
                Label("Verified — reports will arrive at \(viewModel.settings.smtpVerifiedEmail).", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Change…") { viewModel.forgetEmailVerification() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            Label(
                viewModel.settings.smtpVerifiedEmail.isEmpty
                    ? "This address has not been verified yet, so no report can be delivered to it."
                    : "The address changed since it was verified. Verify the new one, or reports will not be delivered.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            if viewModel.isAwaitingVerificationCode {
                HStack {
                    TextField("6-digit code", text: $viewModel.verificationCode, prompt: Text("123456"))
                        .frame(maxWidth: 120)
                    if viewModel.isConfirmingVerification {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Verify") { Task { await viewModel.confirmEmailVerification() } }
                            .disabled(viewModel.verificationCode.isEmpty)
                        Button("Resend") { Task { await viewModel.startEmailVerification() } }
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
            } else {
                HStack {
                    Spacer()
                    if viewModel.isStartingVerification {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send Verification Code") { Task { await viewModel.startEmailVerification() } }
                            .disabled(viewModel.settings.smtpRecipientEmail.isEmpty)
                    }
                }
            }
        }

        if let message = viewModel.verificationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A number field the user can type an exact value into, plus a Stepper
    /// for quick nudges — replaces a bare `Stepper` label, which only let
    /// wide-range settings (e.g. 0...365 days) move one click at a time.
    @ViewBuilder
    private func labeledStepper(
        _ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
        suffix: String? = nil, zeroMeans: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                NumberField(value: value, range: range)
                if let suffix {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
            if let zeroMeans, value.wrappedValue == 0 {
                Text("0 = \(zeroMeans)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Backs `labeledStepper`'s editable number. `TextField(value:format:)`
    /// alone isn't strict enough here: `.number` still accepts things like
    /// grouping commas or a leading minus sign that don't make sense for
    /// these settings, and re-deriving the displayed string from a clamped
    /// `Binding<Int>` on every keystroke fights the user mid-type (e.g.
    /// typing "45" into a 1...90 field briefly reads back "4" then "45",
    /// but typing "99" into that same field snaps to "90" before they can
    /// backspace). Instead: non-digit characters are stripped as typed, the
    /// text is free to hold any digit string while focused, and the value
    /// only round-trips through `range` (parse, clamp, re-render) once on
    /// blur/Return — so the bound `AppSettings` field is never assigned
    /// anything outside `range`, but the field itself doesn't self-correct
    /// out from under an in-progress keystroke.
    private struct NumberField: View {
        @Binding var value: Int
        let range: ClosedRange<Int>

        @State private var text: String = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($isFocused)
                .onAppear { text = String(value) }
                .onChange(of: value) { _, newValue in
                    if !isFocused { text = String(newValue) }
                }
                .onChange(of: text) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue { text = digitsOnly }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
        }

        private func commit() {
            let parsed = Int(text) ?? range.lowerBound
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = clamped
            text = String(clamped)
        }
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                // The returned flag was being discarded. macOS can register
                // the item and still hold it until the user approves it in
                // System Settings, which leaves the toggle on while the app
                // doesn't actually launch at login — worth saying out loud
                // rather than letting it look finished.
                loginItemNeedsApproval = try LoginItemManager.shared.enable()
            } else {
                try LoginItemManager.shared.disable()
                loginItemNeedsApproval = false
            }
            loginItemEnabled = LoginItemManager.shared.isEnabled
        } catch {
            loginItemError = error.localizedDescription
            loginItemNeedsApproval = false
            loginItemEnabled = LoginItemManager.shared.isEnabled
        }
    }
}
