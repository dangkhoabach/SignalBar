import SignalBarCore
import SwiftUI

/// Everything known about one device, the fields the user keeps for it, and
/// what can be done with it.
struct NetworkDeviceDetailView: View {
    let deviceID: Int64

    @Bindable private var viewModel = NetworkViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NetworkDevice?
    @State private var history: [NetworkIPHistoryEntry] = []
    @State private var sightings: [NetworkSighting] = []
    @State private var events: [NetworkEvent] = []
    @State private var ports: [NetworkPortResult] = []
    @State private var isScanningPorts = false
    @State private var customPorts = ""
    @State private var isConfirmingDelete = false
    @State private var mergeTarget: NetworkDevice?

    private var device: NetworkDevice? { viewModel.device(id: deviceID) }

    var body: some View {
        Group {
            if let device, draft != nil {
                form(device)
                    .navigationTitle(device.name)
            } else {
                ContentUnavailableView("Device not found", systemImage: "questionmark.circle",
                                       description: Text("It was deleted or merged into another device."))
            }
        }
        .onAppear(perform: load)
        .onChange(of: device) { _, _ in reloadRecords() }
        .confirmationDialog("Delete this device?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.deleteDevices(ids: [deviceID])
                dismiss()
            }
        } message: {
            Text("Its history goes too. If it is still on the network, the next scan finds it again as a new device.")
        }
        .confirmationDialog(
            "Merge into \(mergeTarget?.name ?? "")?", isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge") {
                if let target = mergeTarget?.id { viewModel.merge(deviceID, into: target) }
                mergeTarget = nil
                dismiss()
            }
        } message: {
            Text("This device's history, addresses and notes move to the other one, and this one is removed. Use it when a phone that changes its private address shows up as a new device.")
        }
    }

    private func load() {
        viewModel.start()
        draft = device
        reloadRecords()
    }

    private func reloadRecords() {
        history = viewModel.history(deviceID: deviceID)
        sightings = viewModel.sightings(deviceID: deviceID)
        events = viewModel.events(deviceID: deviceID)
        ports = viewModel.ports(deviceID: deviceID)
    }

    /// Saves as the user edits; the repository only writes the user's own
    /// fields, so a scan landing at the same time is never undone.
    private func binding<T>(_ keyPath: WritableKeyPath<NetworkDevice, T>) -> Binding<T> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { value in
                draft![keyPath: keyPath] = value
                if let draft { viewModel.update(draft) }
            }
        )
    }

    private func form(_ device: NetworkDevice) -> some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(device.state.color).frame(width: 8, height: 8)
                        Text(device.state.label)
                        if viewModel.isStale(device) { Text("(stale)").foregroundStyle(.secondary) }
                    }
                }
                LabeledContent("IP address") { Text(device.currentIP ?? "—").textSelection(.enabled).monospacedDigit() }
                LabeledContent("MAC address") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let mac = device.mac {
                            Text(mac).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        } else {
                            Text("Unknown: seen only through a router")
                        }
                        if device.hasPrivateMAC {
                            Text("Private address, set by the device itself").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Manufacturer", value: device.vendor ?? "—")
                LabeledContent("Hostname") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(device.hostname ?? "—").textSelection(.enabled)
                        if let source = device.hostnameSource { Text(source.label).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                LabeledContent("Network") {
                    Text(verbatim: [viewModel.subnet(id: device.subnetID).map { "\($0.name) (\($0.cidr))" },
                                    (device.vlanID ?? viewModel.subnet(id: device.subnetID)?.vlanID).map { "VLAN \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                if let port = device.switchPort {
                    LabeledContent("Switch port", value: [device.switchName, port].compactMap { $0 }.joined(separator: " · "))
                }
                if let server = viewModel.serverName(for: device) {
                    LabeledContent("Server Manager", value: server)
                }
                LabeledContent("First seen") { Text(device.firstSeenAt, format: .dateTime) }
                LabeledContent("Last seen") {
                    if let seen = device.lastSeenAt { Text(seen, format: .dateTime) } else { Text("Never on the network") }
                }
            }

            Section("Yours") {
                TextField("Name", text: Binding(get: { draft?.displayName ?? "" }, set: { binding(\.displayName).wrappedValue = $0 }),
                          prompt: Text(device.hostname ?? device.currentIP ?? ""))
                Picker("Type", selection: binding(\.deviceType)) {
                    ForEach(NetworkDeviceType.allCases, id: \.self) { type in
                        Label(type.label, systemImage: type.systemImage).tag(type)
                    }
                }
                TextField("Notes", text: Binding(get: { draft?.notes ?? "" }, set: { binding(\.notes).wrappedValue = $0 }), axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Watch: alert when it leaves the network or comes back", isOn: binding(\.isWatched))
                Toggle("Hide from the device list", isOn: binding(\.isIgnored))
                Toggle("Its address is shared on purpose (VRRP, cluster): no conflict alerts", isOn: binding(\.ignoreConflicts))
            }

            Section("Actions") {
                if let ip = device.currentIP {
                    HStack {
                        Button("Monitor as a Domain…") {
                            AppNavigationState.shared.openNewTarget(name: device.name, url: "http://\(ip)")
                        }
                        Button("Add to Server Manager…") {
                            AppNavigationState.shared.openNewServer(name: device.name, host: ip)
                        }
                    }
                }
                HStack {
                    Menu("Merge into…") {
                        ForEach(viewModel.devices.filter { $0.id != deviceID && $0.subnetID == device.subnetID }.sorted { $0.name < $1.name }) { other in
                            Button { mergeTarget = other } label: {
                                Text(verbatim: "\(other.name) — \(other.currentIP ?? other.mac ?? "")")
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Delete Device…", role: .destructive) { isConfirmingDelete = true }
                }
            }

            portsSection(device)

            if !viewModel.leases(for: device).isEmpty {
                Section("DHCP") {
                    ForEach(viewModel.leases(for: device), id: \.rowKey) { lease in
                        LabeledContent {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(lease.isReserved ? "Reserved" : lease.isActive ? "Active lease" : "Expired lease")
                                if let ends = lease.endsAt {
                                    Text("Until \(ends, format: .dateTime)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Text(verbatim: "\(lease.ip) · \(viewModel.source(id: lease.sourceID)?.name ?? "")")
                        }
                    }
                }
            }

            Section("Address history") {
                ForEach(history, id: \.rowKey) { entry in
                    LabeledContent(entry.ip) {
                        Text(verbatim: "\(entry.firstSeenAt.formatted(date: .abbreviated, time: .shortened)) – \(entry.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                if history.isEmpty { Text("No address recorded yet.").foregroundStyle(.secondary) }
            }

            Section("Seen by") {
                ForEach(sightings, id: \.rowKey) { sighting in
                    LabeledContent {
                        Text(sighting.lastSeenAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sighting.source.label)
                            Text(verbatim: [sighting.ip, viewModel.source(id: sighting.sourceID)?.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Activity") {
                ForEach(events.prefix(50), id: \.rowKey) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: event.kind.systemImage).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.label)
                            if let detail = eventDetail(event) { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(event.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if events.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func eventDetail(_ event: NetworkEvent) -> String? {
        switch event.kind {
        case .ipChanged: return [event.detail, event.ip].compactMap { $0 }.joined(separator: " → ")
        case .ipOwnerChanged, .conflict:
            let others = (event.detail ?? "").split(separator: ",").compactMap { Int64($0) }.compactMap { viewModel.device(id: $0)?.name }
            return [event.ip, others.isEmpty ? nil : others.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
        case .portOpened, .portClosed: return event.detail.map { "TCP \($0)" }
        default: return event.ip
        }
    }

    @ViewBuilder
    private func portsSection(_ device: NetworkDevice) -> some View {
        Section {
            if device.currentIP == nil {
                Text("No address to scan.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Common ports") { scanPorts(NetworkMonitor.commonPorts) }
                    Button("More ports") { scanPorts(NetworkMonitor.extendedPorts) }
                    TextField("Ports", text: $customPorts, prompt: Text("Ports, e.g. 22, 8000-8010"))
                        .labelsHidden()
                        .frame(minWidth: 160)
                        .onSubmit { scanPorts(Self.parsePorts(customPorts)) }
                    Button("Scan") { scanPorts(Self.parsePorts(customPorts)) }
                        .disabled(Self.parsePorts(customPorts).isEmpty)
                    if isScanningPorts { ProgressView().controlSize(.small) }
                }
                .disabled(isScanningPorts)
                ForEach(ports.filter { $0.state == .open }, id: \.rowKey) { port in
                    LabeledContent {
                        Text(port.latencyMs.map { String(format: "%.0f ms", $0) } ?? "").foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "TCP \(port.port) \(Self.serviceName(port.port).map { "· \($0)" } ?? "")")
                    }
                }
                if let last = ports.map(\.scannedAt).max() {
                    let closed = ports.filter { $0.state != .open }.count
                    Text("\(ports.filter { $0.state == .open }.count) open, \(closed) closed or filtered · \(last, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Open ports")
        } footer: {
            Text("A plain TCP connection to each port, only when you ask. Nothing is probed beyond whether the port accepts a connection.")
        }
    }

    private func scanPorts(_ list: [Int]) {
        guard !list.isEmpty else { return }
        isScanningPorts = true
        Task {
            ports = await viewModel.scanPorts(deviceID: deviceID, ports: list)
            events = viewModel.events(deviceID: deviceID)
            isScanningPorts = false
        }
    }

    /// `22, 80, 8000-8010` → the ports, at most 1,024 of them.
    static func parsePorts(_ text: String) -> [Int] {
        var ports: [Int] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1, (1...65_535).contains(bounds[0]) {
                ports.append(bounds[0])
            } else if bounds.count == 2, (1...65_535).contains(bounds[0]), (bounds[0]...65_535).contains(bounds[1]) {
                ports += Array(bounds[0]...min(bounds[1], bounds[0] + 1_023))
            }
        }
        return Array(Set(ports)).sorted().prefix(1_024).map { $0 }
    }

    /// The usual service on a well-known port; a guess, labelled as such by
    /// being only a name next to the number.
    static func serviceName(_ port: Int) -> String? {
        [21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3", 135: "RPC", 139: "NetBIOS",
         143: "IMAP", 443: "HTTPS", 445: "SMB", 515: "LPD", 548: "AFP", 554: "RTSP", 631: "IPP", 993: "IMAPS", 995: "POP3S",
         1433: "SQL Server", 1883: "MQTT", 3306: "MySQL", 3389: "RDP", 5000: "UPnP / Synology", 5432: "PostgreSQL",
         5900: "VNC", 6379: "Redis", 8006: "Proxmox", 8080: "HTTP alt", 8443: "HTTPS alt", 8883: "MQTT TLS",
         9100: "Printer", 27017: "MongoDB"][port]
    }
}

// One Form holds several lists whose own ids can coincide (a history row and
// an event both numbered 3); SwiftUI then reuses one row for the other.
// These keys stay distinct across the lists.
private extension NetworkIPHistoryEntry { var rowKey: String { "history-\(id ?? 0)" } }
private extension NetworkEvent { var rowKey: String { "event-\(id ?? 0)" } }
private extension NetworkPortResult { var rowKey: String { "port-\(port)" } }
private extension NetworkDHCPLease { var rowKey: String { "lease-\(sourceID)-\(ip)" } }
private extension NetworkSighting { var rowKey: String { "seen-\(source.rawValue)-\(sourceID)-\(ip)" } }
