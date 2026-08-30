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
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    @State private var loginItemError: String?
    @State private var isPresentingClearAllConfirm = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themePreferenceRaw) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Language", selection: Binding(
                    get: { AppLocale(rawValue: languageRaw) ?? .systemDefault },
                    set: { languageRaw = $0.rawValue }
                )) {
                    Text("VI").tag(AppLocale.vi)
                    Text("EN").tag(AppLocale.en)
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { setLoginItemEnabled($0) }
                ))

                Toggle("Enable Notifications", isOn: Binding(
                    get: { viewModel.settings.notificationsEnabled },
                    set: { newValue in
                        viewModel.settings.notificationsEnabled = newValue
                        if newValue {
                            Task {
                                await NotificationManager.shared.requestAuthorization()
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
                    }
                ))
                Text("Get notified when a domain goes down or an SSL/domain expiry is approaching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Manage in System Settings…") {
                    NotificationManager.openSystemNotificationSettings()
                }
            }

            Section("Health Checks") {
                labeledStepper("Failure alert threshold", value: $viewModel.settings.failureAlertThreshold, in: 1...20, suffix: "checks")
                labeledStepper(
                    "Slow response threshold",
                    value: $viewModel.settings.responseTimeAlertThresholdMs, in: 0...30000, step: 500,
                    display: viewModel.settings.responseTimeAlertThresholdMs == 0 ? "off" : "\(viewModel.settings.responseTimeAlertThresholdMs)ms"
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
                    display: viewModel.settings.systemTempAlertThresholdCelsius == 0 ? "off" : "\(viewModel.settings.systemTempAlertThresholdCelsius)°C"
                )
                labeledStepper(
                    "Low battery alert",
                    value: $viewModel.settings.batteryLowAlertThresholdPercent, in: 0...100,
                    display: viewModel.settings.batteryLowAlertThresholdPercent == 0 ? "off" : "\(viewModel.settings.batteryLowAlertThresholdPercent)%"
                )
            }

            Section("History") {
                labeledStepper(
                    "Retention",
                    value: $viewModel.settings.historyRetentionDays, in: 0...365, step: 5,
                    display: viewModel.settings.historyRetentionDays == 0 ? "forever" : "\(viewModel.settings.historyRetentionDays) days"
                )
            }

            Section("Email Report") {
                Toggle("Enable Email Reports", isOn: $viewModel.settings.smtpEnabled)
                if viewModel.settings.smtpEnabled {
                    TextField("Recipient Email", text: $viewModel.settings.smtpRecipientEmail, prompt: Text("you@example.com"))
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
                                .disabled(viewModel.settings.smtpRecipientEmail.isEmpty)
                        }
                    }
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

    @ViewBuilder
    private func labeledStepper(
        _ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
        display: String? = nil, suffix: String? = nil
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(display ?? "\(value.wrappedValue)\(suffix.map { " \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try LoginItemManager.shared.enable()
            } else {
                try LoginItemManager.shared.disable()
            }
            loginItemEnabled = LoginItemManager.shared.isEnabled
        } catch {
            loginItemError = error.localizedDescription
            loginItemEnabled = LoginItemManager.shared.isEnabled
        }
    }
}
