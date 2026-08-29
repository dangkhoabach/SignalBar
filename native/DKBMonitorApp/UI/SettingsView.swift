import DKBMonitorCore
import SwiftUI

/// The macOS `Settings {}` scene content (Cmd+,) — `TabView` groups per
/// Mục 3/Phase 12: General, Alerts & Data, Email Report. Every field writes
/// straight through `SettingsViewModel.settings`'s `didSet`, so there's no
/// separate Save button — matches the standard System Settings idiom.
struct SettingsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    @AppStorage("themePreference") private var themePreferenceRaw = ThemePreference.system.rawValue
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            alertsTab
                .tabItem { Label("Alerts & Data", systemImage: "bell") }
            emailTab
                .tabItem { Label("Email Report", systemImage: "envelope") }
        }
        .frame(width: 460, height: 360)
        .onAppear { viewModel.loadIfNeeded() }
        .alert("Login Item Error", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK", role: .cancel) { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
    }

    private var generalTab: some View {
        Form {
            Picker("Appearance", selection: $themePreferenceRaw) {
                ForEach(ThemePreference.allCases) { theme in
                    Text(theme.label).tag(theme.rawValue)
                }
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemEnabled },
                set: { setLoginItemEnabled($0) }
            ))

            Toggle("Enable Notifications", isOn: Binding(
                get: { viewModel.settings.notificationsEnabled },
                set: { newValue in
                    viewModel.settings.notificationsEnabled = newValue
                    if newValue {
                        Task { await NotificationManager.shared.requestAuthorization() }
                    }
                }
            ))
            Button("Manage in System Settings…") {
                NotificationManager.openSystemNotificationSettings()
            }
        }
        .formStyle(.grouped)
    }

    private var alertsTab: some View {
        Form {
            Section("Health Checks") {
                Stepper("Failure alert threshold: \(viewModel.settings.failureAlertThreshold)", value: $viewModel.settings.failureAlertThreshold, in: 1...20)
                Stepper(
                    "Slow response threshold: \(viewModel.settings.responseTimeAlertThresholdMs == 0 ? "off" : "\(viewModel.settings.responseTimeAlertThresholdMs)ms")",
                    value: $viewModel.settings.responseTimeAlertThresholdMs, in: 0...30000, step: 500
                )
            }
            Section("Expiry") {
                Stepper("SSL alert: \(viewModel.settings.sslAlertThresholdDays) days before", value: $viewModel.settings.sslAlertThresholdDays, in: 1...90)
                Stepper("Domain alert: \(viewModel.settings.domainAlertThresholdDays) days before", value: $viewModel.settings.domainAlertThresholdDays, in: 1...90)
            }
            Section("System") {
                Stepper(
                    "High temperature alert: \(viewModel.settings.systemTempAlertThresholdCelsius == 0 ? "off" : "\(viewModel.settings.systemTempAlertThresholdCelsius)°C")",
                    value: $viewModel.settings.systemTempAlertThresholdCelsius, in: 0...100
                )
                Stepper(
                    "Low battery alert: \(viewModel.settings.batteryLowAlertThresholdPercent == 0 ? "off" : "\(viewModel.settings.batteryLowAlertThresholdPercent)%")",
                    value: $viewModel.settings.batteryLowAlertThresholdPercent, in: 0...100
                )
            }
            Section("History") {
                Stepper(
                    "Retention: \(viewModel.settings.historyRetentionDays == 0 ? "forever" : "\(viewModel.settings.historyRetentionDays) days")",
                    value: $viewModel.settings.historyRetentionDays, in: 0...365, step: 5
                )
            }
        }
        .formStyle(.grouped)
    }

    private var emailTab: some View {
        Form {
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
            }
        }
        .formStyle(.grouped)
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
