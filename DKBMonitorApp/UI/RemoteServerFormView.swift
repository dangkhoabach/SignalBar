import DKBMonitorCore
import SwiftUI

/// Add/edit sheet for a `RemoteServer`. Per D2 in the plan: private key is
/// the recommended auth method, password is a supported fallback — both get
/// identical Keychain protection (see `KeychainStore`), so this view doesn't
/// treat one as "less safe" to store, only nudges the user's choice.
struct RemoteServerFormView: View {
    enum Mode {
        case add
        case edit(RemoteServer)
    }

    let mode: Mode
    let onSave: (NewRemoteServerInput) -> Void
    let onUpdate: (RemoteServer, SSHAuthCredential?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var groupTag: String
    @State private var monitoringEnabled: Bool
    @State private var authMethod: RemoteAuthMethod
    @State private var privateKeyPEM: String = ""
    @State private var passphrase: String = ""
    @State private var password: String = ""

    init(
        mode: Mode,
        onSave: @escaping (NewRemoteServerInput) -> Void = { _ in },
        onUpdate: @escaping (RemoteServer, SSHAuthCredential?) -> Void = { _, _ in }
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onUpdate = onUpdate
        let server: RemoteServer? = if case .edit(let existing) = mode { existing } else { nil }
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _portText = State(initialValue: String(server?.port ?? 22))
        _username = State(initialValue: server?.username ?? "")
        _groupTag = State(initialValue: server?.groupTag ?? "")
        _monitoringEnabled = State(initialValue: server?.monitoringEnabled ?? false)
        _authMethod = State(initialValue: server?.authMethod ?? .privateKey)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var port: Int? {
        guard let value = Int(portText), (1...65535).contains(value) else { return nil }
        return value
    }

    /// Editing an existing server never *requires* re-entering the
    /// credential (leaving the field blank keeps the one already in
    /// Keychain) — only adding a new one does.
    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !host.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty,
              port != nil
        else { return false }

        if isEditing { return true }

        switch authMethod {
        case .privateKey: return !privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password: return !password.isEmpty
        }
    }

    private var newCredentialIfProvided: SSHAuthCredential? {
        switch authMethod {
        case .privateKey:
            let trimmed = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .privateKey(pem: trimmed, passphrase: passphrase.isEmpty ? nil : passphrase)
        case .password:
            guard !password.isEmpty else { return nil }
            return .password(password)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host, prompt: Text("1.2.3.4 or example.com"))
                    TextField("Port", text: $portText)
                    TextField("Username", text: $username, prompt: Text("root"))
                    TextField("Group (optional)", text: $groupTag)
                }
                Section("Monitoring") {
                    Toggle("Watch CPU, RAM and disk", isOn: $monitoringEnabled)
                    // Off by default and per server on purpose: a server was
                    // added here to be managed by hand, and putting it on a
                    // timer means a scheduled SSH connection every few
                    // minutes. That is worth opting into rather than
                    // inheriting from a global setting.
                    Text("Connects every few minutes to read this server's usage, and alerts when it crosses the thresholds in Settings. Leave off to only reach this server when you ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Private key (recommended)").tag(RemoteAuthMethod.privateKey)
                        Text("Password").tag(RemoteAuthMethod.password)
                    }
                    .pickerStyle(.segmented)

                    if isEditing {
                        Text("Leave blank to keep the credential already stored in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    switch authMethod {
                    case .privateKey:
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 100)
                        SecureField("Passphrase (optional)", text: $passphrase)
                    case .password:
                        SecureField("Password", text: $password)
                    }
                }
                Section {
                    Text("The credential is stored in Keychain (unlocked-device-only, never synced to iCloud) — never in the app's database.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { save() }
                        .disabled(!isValid)
                }
            }
        }
        .frame(width: 460, height: 480)
    }

    private func save() {
        guard let port else { return }
        let trimmedGroup = groupTag.trimmingCharacters(in: .whitespaces)

        switch mode {
        case .add:
            guard let credential = newCredentialIfProvided else { return }
            onSave(NewRemoteServerInput(
                name: name.trimmingCharacters(in: .whitespaces),
                host: host.trimmingCharacters(in: .whitespaces),
                port: port,
                username: username.trimmingCharacters(in: .whitespaces),
                credential: credential,
                groupTag: trimmedGroup.isEmpty ? nil : trimmedGroup,
                monitoringEnabled: monitoringEnabled
            ))
        case .edit(var server):
            server.name = name.trimmingCharacters(in: .whitespaces)
            server.host = host.trimmingCharacters(in: .whitespaces)
            server.port = port
            server.username = username.trimmingCharacters(in: .whitespaces)
            server.groupTag = trimmedGroup.isEmpty ? nil : trimmedGroup
            server.monitoringEnabled = monitoringEnabled
            onUpdate(server, newCredentialIfProvided)
        }
        dismiss()
    }
}
