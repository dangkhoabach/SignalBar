import SignalBarCore
import SwiftUI

/// Add or edit a managed subnet.
struct NetworkSubnetFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var viewModel = NetworkViewModel.shared
    @State private var draft: NetworkSubnet
    @State private var vlanText: String
    private let isNew: Bool

    init(subnet: NetworkSubnet?) {
        let value = subnet ?? NetworkSubnet(name: "", cidr: "")
        _draft = State(initialValue: value)
        _vlanText = State(initialValue: value.vlanID.map(String.init) ?? "")
        isNew = subnet == nil
    }

    private var network: IPv4CIDR? { IPv4CIDR(draft.cidr) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Office LAN, Cameras, Guest Wi-Fi…"))
                TextField("Subnet", text: $draft.cidr, prompt: Text(verbatim: "192.168.1.0/24"))
                if let network {
                    Text("\(network.description): \(network.hosts.count) addresses")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("VLAN ID", text: $vlanText, prompt: Text("Optional"))
                TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("The VLAN ID is a label for you. It doesn't let this Mac reach a VLAN it isn't on.")
            }
            Section {
                Toggle("Scan from this Mac", isOn: $draft.scanEnabled)
                if draft.scanEnabled {
                    Picker("Every", selection: $draft.scanIntervalSecs) {
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1_800)
                        Text("1 hour").tag(3_600)
                        Text("6 hours").tag(21_600)
                    }
                }
            } footer: {
                Text("Turn scanning off for a subnet known only through a router or DHCP server, or one whose switches limit ARP traffic: a scan sends one ARP request per address, several times.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    draft.vlanID = Int(vlanText.trimmingCharacters(in: .whitespaces)).flatMap { (1...4094).contains($0) ? $0 : nil }
                    if viewModel.save(draft) { dismiss() }
                }
                .disabled(network == nil)
            }
        }
        .networkAlerts(viewModel)
    }
}

/// Add or edit a source: an SNMP router or switch, or a DHCP server.
/// Secrets are written to the Keychain on save; a secret field left empty
/// when editing keeps the stored one.
struct NetworkSourceFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var viewModel = NetworkViewModel.shared
    @State private var draft: NetworkSource
    @State private var portText: String
    @State private var community = ""
    @State private var authPassword = ""
    @State private var privPassword = ""
    @State private var routerPassword = ""
    private let isNew: Bool

    init(source: NetworkSource) {
        var value = source
        if source.id == nil, source.kind == .snmp {
            value.snmpVersion = .v3
            value.authProtocol = .sha256
            value.privProtocol = .aes128
            value.roles = SNMPRoles([.arpTable, .interfaces]).rawValue
        }
        if source.id == nil, source.kind.isDHCP, value.leaseFormat == nil {
            value.leaseFormat = source.kind == .dhcpImport ? .csv : .dnsmasq
            value.leasePath = value.leaseFormat?.defaultPath
        }
        _draft = State(initialValue: value)
        _portText = State(initialValue: String(value.port))
        isNew = source.id == nil
    }

    private var port: Int? {
        guard let value = Int(portText), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var isValid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch draft.kind {
        case .snmp, .dhcpMikroTik: return !draft.host.trimmingCharacters(in: .whitespaces).isEmpty && port != nil
        case .dhcpSSH: return draft.remoteServerID != nil && !(draft.leasePath ?? "").isEmpty
        case .dhcpImport: return true
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Core switch, Main router…"))
                switch draft.kind {
                case .snmp, .dhcpMikroTik:
                    TextField("Address", text: $draft.host, prompt: Text(verbatim: "10.0.0.1"))
                    TextField("Port", text: $portText)
                case .dhcpSSH:
                    sshFields
                case .dhcpImport:
                    Picker("Format", selection: Binding(get: { draft.leaseFormat ?? .csv }, set: { draft.leaseFormat = $0 })) {
                        ForEach(DHCPLeaseFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            } header: {
                Text(draft.kind.label)
            } footer: {
                footer
            }

            switch draft.kind {
            case .snmp: snmpSections
            case .dhcpMikroTik: mikroTikSection
            default: EmptyView()
            }

            if draft.kind != .dhcpImport {
                Section {
                    Picker("Read every", selection: $draft.pollIntervalSecs) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("1 hour").tag(3_600)
                    }
                    Toggle("Read on a schedule", isOn: $draft.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save", action: save).disabled(!isValid)
            }
        }
        .networkAlerts(viewModel)
    }

    @ViewBuilder
    private var footer: some View {
        switch draft.kind {
        case .snmp:
            Text("Read only: SignalBar never changes anything on the device. Uses standard MIB-2 tables, so most routers and managed switches work.")
        case .dhcpSSH:
            Text("Reads the lease file over SSH with a server from the Server Manager, using its stored key. The file is added to that server's allowlist; nothing else can be read.")
        case .dhcpMikroTik:
            Text("RouterOS 7's REST API over HTTPS. The router's certificate is trusted the first time and must not change afterwards.")
        case .dhcpImport:
            Text("For a DHCP server SignalBar can't reach, or a list of reservations: export it to a file and import it from this source's menu.")
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        Picker("Server", selection: $draft.remoteServerID) {
            Text("Choose…").tag(Int64?.none)
            ForEach(viewModel.remoteServers) { server in
                Text(verbatim: "\(server.name) (\(server.host))").tag(server.id)
            }
        }
        Picker("Format", selection: Binding(
            get: { draft.leaseFormat ?? .dnsmasq },
            set: { format in
                if (draft.leasePath ?? "").isEmpty || draft.leasePath == draft.leaseFormat?.defaultPath { draft.leasePath = format.defaultPath }
                draft.leaseFormat = format
            }
        )) {
            ForEach(DHCPLeaseFormat.allCases.filter { $0 != .csv }, id: \.self) { Text($0.label).tag($0) }
        }
        TextField("Lease file", text: Binding(get: { draft.leasePath ?? "" }, set: { draft.leasePath = $0 }))
        if viewModel.remoteServers.isEmpty {
            Text("Add the DHCP server in the Server Manager first.").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var snmpSections: some View {
        Section("Access") {
            Picker("Version", selection: Binding(get: { draft.snmpVersion ?? .v3 }, set: { draft.snmpVersion = $0 })) {
                Text(verbatim: "SNMPv3").tag(SNMPCredentials.Version.v3)
                Text(verbatim: "SNMPv2c").tag(SNMPCredentials.Version.v2c)
            }
            .pickerStyle(.segmented)
            if draft.snmpVersion == .v2c {
                SecureField("Community", text: $community, prompt: Text(secretPrompt(.snmpCommunity)))
                Label("v2c sends the community in clear text. Prefer v3 where the device supports it.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                TextField("User", text: Binding(get: { draft.username ?? "" }, set: { draft.username = $0 }))
                Picker("Authentication", selection: $draft.authProtocol) {
                    Text("None").tag(SNMPAuthProtocol?.none)
                    Text(verbatim: "SHA-256").tag(SNMPAuthProtocol?.some(.sha256))
                    Text(verbatim: "SHA-1").tag(SNMPAuthProtocol?.some(.sha1))
                    Text(verbatim: "MD5").tag(SNMPAuthProtocol?.some(.md5))
                }
                if draft.authProtocol != nil {
                    SecureField("Authentication password", text: $authPassword, prompt: Text(secretPrompt(.snmpAuthPassword)))
                    Picker("Privacy", selection: $draft.privProtocol) {
                        Text("None").tag(SNMPPrivProtocol?.none)
                        Text(verbatim: "AES-128").tag(SNMPPrivProtocol?.some(.aes128))
                    }
                    if draft.privProtocol != nil {
                        SecureField("Privacy password", text: $privPassword, prompt: Text(secretPrompt(.snmpPrivPassword)))
                    }
                }
            }
        }
        Section {
            Toggle("ARP table: the devices of every VLAN it routes", isOn: roleBinding(.arpTable))
            Toggle("MAC table: which VLAN and port each device is on", isOn: roleBinding(.macTable))
            Toggle("Interfaces: status and traffic", isOn: roleBinding(.interfaces))
        } header: {
            Text("Read")
        } footer: {
            Text("Turn on the ARP table for routers and layer-3 switches, the MAC table for switches.")
        }
    }

    private var mikroTikSection: some View {
        Section("Access") {
            TextField("User", text: Binding(get: { draft.username ?? "" }, set: { draft.username = $0 }))
            SecureField("Password", text: $routerPassword, prompt: Text(secretPrompt(.routerPassword)))
            if let fingerprint = draft.tlsFingerprint {
                LabeledContent("Trusted certificate") {
                    Text(fingerprint.prefix(23) + "…").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    private func roleBinding(_ role: SNMPRoles) -> Binding<Bool> {
        Binding(
            get: { draft.snmpRoles.contains(role) },
            set: { isOn in
                var roles = draft.snmpRoles
                if isOn { roles.insert(role) } else { roles.remove(role) }
                draft.roles = roles.rawValue
            }
        )
    }

    private func secretPrompt(_ kind: KeychainSecretKind) -> LocalizedStringKey {
        !isNew && viewModel.hasSecret(kind, for: draft) ? "Stored; leave empty to keep it" : ""
    }

    private func save() {
        var source = draft
        source.name = source.name.trimmingCharacters(in: .whitespaces)
        source.host = source.host.trimmingCharacters(in: .whitespaces)
        source.port = port ?? source.port
        // Encryption needs authentication; SNMPv3 has no priv-without-auth.
        if source.authProtocol == nil { source.privProtocol = nil }
        // Only fields the user typed into are written: empty means "keep".
        var secrets: [KeychainSecretKind: String] = [:]
        let typed: [(KeychainSecretKind, String)] = [
            (.snmpCommunity, community), (.snmpAuthPassword, authPassword), (.snmpPrivPassword, privPassword), (.routerPassword, routerPassword),
        ]
        for (kind, value) in typed where !value.isEmpty { secrets[kind] = value }
        if viewModel.save(source, secrets: secrets) { dismiss() }
    }
}
