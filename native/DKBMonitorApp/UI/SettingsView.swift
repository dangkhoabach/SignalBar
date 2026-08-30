import DKBMonitorCore
import SwiftUI

/// The app's unified Settings tab (sidebar + app menu Cmd+, + menu bar both
/// route here, see `WindowPresenter.showSettings()`). Laid out as a scrolling
/// column of `GroupBox` cards — the same chrome/spacing `SystemView` uses for
/// its metric cards — rather than the earlier floating `TabView` panel, so
/// this tab fills the detail pane and reads as the same kind of page as
/// Domains/System instead of a narrow centered dialog.
///
/// Sections beyond the original General/Alerts/Email split are ported from
/// the old Tauri app's Settings pages (`src/pages/Settings.tsx`,
/// `AlertsDataSettings.tsx`, `EmailReportSettings.tsx`): "Send Test Email"
/// and the "Data" card (Export/Import/Clear All Domains) existed there but
/// had no equivalent here yet.
struct SettingsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    @Bindable private var overviewViewModel = OverviewViewModel.shared
    @AppStorage("themePreference") private var themePreferenceRaw = ThemePreference.system.rawValue
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    @State private var loginItemError: String?
    @State private var isPresentingClearAllConfirm = false

    private static let outerPadding: CGFloat = 24
    private static let sectionSpacing: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                generalSection
                alertsSection
                emailSection
                dataSection
            }
            .padding(Self.outerPadding)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    // MARK: - Sections

    private var generalSection: some View {
        section(title: "General", systemImage: "gearshape") {
            Picker("Appearance", selection: $themePreferenceRaw) {
                ForEach(ThemePreference.allCases) { theme in
                    Text(theme.label).tag(theme.rawValue)
                }
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemEnabled },
                set: { setLoginItemEnabled($0) }
            ))
            Divider()
            Toggle("Enable Notifications", isOn: Binding(
                get: { viewModel.settings.notificationsEnabled },
                set: { newValue in
                    viewModel.settings.notificationsEnabled = newValue
                    if newValue {
                        Task {
                            await NotificationManager.shared.requestAuthorization()
                            // Fires a real notification on enable, same as the
                            // old Tauri app's handleNotificationsToggle — this
                            // is also what actually triggers the first-use
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
            Button("Manage in System Settings…") {
                NotificationManager.openSystemNotificationSettings()
            }
        }
    }

    private var alertsSection: some View {
        section(title: "Alerts & Data", systemImage: "bell") {
            labeledStepper("Failure alert threshold", value: $viewModel.settings.failureAlertThreshold, in: 1...20, suffix: "checks")
            labeledStepper(
                "Slow response threshold",
                value: $viewModel.settings.responseTimeAlertThresholdMs, in: 0...30000, step: 500,
                display: viewModel.settings.responseTimeAlertThresholdMs == 0 ? "off" : "\(viewModel.settings.responseTimeAlertThresholdMs)ms"
            )
            Divider()
            labeledStepper("SSL alert", value: $viewModel.settings.sslAlertThresholdDays, in: 1...90, suffix: "days before")
            labeledStepper("Domain alert", value: $viewModel.settings.domainAlertThresholdDays, in: 1...90, suffix: "days before")
            Divider()
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
            Divider()
            labeledStepper(
                "History retention",
                value: $viewModel.settings.historyRetentionDays, in: 0...365, step: 5,
                display: viewModel.settings.historyRetentionDays == 0 ? "forever" : "\(viewModel.settings.historyRetentionDays) days"
            )
        }
    }

    private var emailSection: some View {
        section(title: "Email Report", systemImage: "envelope") {
            Toggle("Enable Email Reports", isOn: $viewModel.settings.smtpEnabled)
            if viewModel.settings.smtpEnabled {
                LabeledContent("Recipient Email") {
                    TextField("you@example.com", text: $viewModel.settings.smtpRecipientEmail)
                        .multilineTextAlignment(.trailing)
                }
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
    }

    /// Ported from Tauri's `AlertsDataSettingsPage` "Domains" card — Export/
    /// Import already existed in the Overview toolbar's menu, but "Clear All
    /// Domains" had no equivalent anywhere in the native app yet.
    private var dataSection: some View {
        section(title: "Data", systemImage: "tray.full") {
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

    // MARK: - Helpers

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

    /// Same `GroupBox` chrome as `SystemView.card` (icon+title header row,
    /// stretched to fill its row) so Settings' cards read as the same visual
    /// language as the System tab's, instead of the earlier `Form` pages
    /// with macOS's built-in `.formStyle(.grouped)` look.
    @ViewBuilder
    private func section<Content: View>(
        title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(title).font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: systemImage)
                }
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
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
