import DKBMonitorCore
import SwiftUI

/// Add/edit sheet. Validation is plain Swift (no Zod-equivalent needed per
/// Phase 11's plan) — just a non-empty name and a URL with a scheme.
struct TargetFormView: View {
    enum Mode {
        case add
        case edit(Target)
    }

    let mode: Mode
    let onSave: (NewTargetInput) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String
    @State private var groupTag: String
    @State private var checkIntervalSecs: Int
    @State private var checkHTTP: Bool
    @State private var expectedStatus: Int
    @State private var checkSSL: Bool
    @State private var checkDomain: Bool
    @State private var customPath: String
    @State private var expectedBodyContains: String

    init(mode: Mode, onSave: @escaping (NewTargetInput) -> Void) {
        self.mode = mode
        self.onSave = onSave
        let target: Target? = if case .edit(let existing) = mode { existing } else { nil }
        SettingsViewModel.shared.loadIfNeeded()
        _name = State(initialValue: target?.name ?? "")
        _url = State(initialValue: target?.url ?? "")
        _groupTag = State(initialValue: target?.groupTag ?? "")
        _checkIntervalSecs = State(initialValue: target?.checkIntervalSecs ?? SettingsViewModel.shared.settings.httpCheckIntervalSecs)
        _checkHTTP = State(initialValue: target?.checkHTTP ?? true)
        _expectedStatus = State(initialValue: target?.expectedStatus ?? 200)
        _checkSSL = State(initialValue: target?.checkSSL ?? true)
        _checkDomain = State(initialValue: target?.checkDomain ?? false)
        _customPath = State(initialValue: target?.customPath ?? "")
        _expectedBodyContains = State(initialValue: target?.expectedBodyContains ?? "")
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isValid: Bool {
        // `URL(string:)` alone happily parses "http://" (scheme, empty
        // host) - checking `.host` catches that case at input time instead
        // of leaving it to fail with a generic error on the first check.
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && url.contains("://")
            && URL(string: url)?.host?.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url, prompt: Text("https://example.com"))
                    TextField("Group (optional)", text: $groupTag, prompt: Text("Auto-detected from domain"))
                }
                Section("Checks") {
                    Toggle("Check HTTP", isOn: $checkHTTP)
                    if checkHTTP {
                        Stepper("Expected status: \(expectedStatus)", value: $expectedStatus, in: 100...599)
                        TextField("Custom path (optional)", text: $customPath, prompt: Text("/health"))
                        TextField("Expected body contains (optional)", text: $expectedBodyContains)
                    }
                    Stepper("Check interval: \(checkIntervalSecs / 60) min", value: $checkIntervalSecs, in: 60...3600, step: 60)
                    Toggle("Check SSL expiry", isOn: $checkSSL)
                    Toggle("Check domain expiry", isOn: $checkDomain)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Target" : "Add Target")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        onSave(NewTargetInput(
                            name: name.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            groupTag: groupTag.isEmpty ? nil : groupTag,
                            checkIntervalSecs: checkIntervalSecs,
                            checkHTTP: checkHTTP,
                            expectedStatus: expectedStatus,
                            checkSSL: checkSSL,
                            checkDomain: checkDomain,
                            customPath: customPath.isEmpty ? nil : customPath,
                            expectedBodyContains: expectedBodyContains.isEmpty ? nil : expectedBodyContains
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(width: 440, height: 420)
    }
}
