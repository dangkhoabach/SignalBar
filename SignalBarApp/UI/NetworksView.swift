import Charts
import SignalBarCore
import SwiftUI

/// Network › Networks: the subnets that are managed and the devices the app
/// reads network information from (SNMP, DHCP).
struct NetworksView: View {
    @Bindable private var viewModel = NetworkViewModel.shared
    @Bindable private var navigationState = AppNavigationState.shared
    @State private var navigationPath = NavigationPath()
    @State private var editingSubnet: NetworkSubnet?
    @State private var isAddingSubnet = false
    @State private var addingSourceKind: NetworkSourceKind?
    @State private var editingSource: NetworkSource?
    @State private var pendingDeleteSubnet: NetworkSubnet?
    @State private var pendingDeleteSource: NetworkSource?
    @State private var suggestions: [IPv4CIDR] = []
    @State private var suggestionSource: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                subnetsSection
                if !viewModel.localSuggestions.isEmpty || !suggestions.isEmpty { suggestionsSection }
                sourcesSection
            }
            .listStyle(.inset)
            .navigationTitle("Networks")
            .navigationDestination(for: Int64.self) { NetworkSourceDetailView(sourceID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Subnet…") { isAddingSubnet = true }
                        Divider()
                        Button("Router or Switch (SNMP)…") { addingSourceKind = .snmp }
                        Button("DHCP Server over SSH…") { addingSourceKind = .dhcpSSH }
                        Button("MikroTik Router (DHCP)…") { addingSourceKind = .dhcpMikroTik }
                        Button("DHCP Leases from a File…") { addingSourceKind = .dhcpImport }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear { viewModel.start() }
        .onChange(of: navigationState.pendingSourceID) { _, id in
            guard let id else { return }
            navigationPath = NavigationPath([id])
            navigationState.pendingSourceID = nil
        }
        .sheet(isPresented: $isAddingSubnet) { NetworkSubnetFormView(subnet: nil) }
        .sheet(item: $editingSubnet) { NetworkSubnetFormView(subnet: $0) }
        .sheet(item: $addingSourceKind) { NetworkSourceFormView(source: NetworkSource(kind: $0, name: "", port: Self.defaultPort($0))) }
        .sheet(item: $editingSource) { NetworkSourceFormView(source: $0) }
        .networkAlerts(viewModel)
        .confirmationDialog(
            "Delete \(pendingDeleteSubnet?.name ?? "")?",
            isPresented: Binding(get: { pendingDeleteSubnet != nil }, set: { if !$0 { pendingDeleteSubnet = nil } }), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteSubnet?.id { viewModel.deleteSubnet(id: id) }
                pendingDeleteSubnet = nil
            }
        } message: {
            Text("Every device found in it, with its history, is deleted too.")
        }
        .confirmationDialog(
            "Delete \(pendingDeleteSource?.name ?? "")?",
            isPresented: Binding(get: { pendingDeleteSource != nil }, set: { if !$0 { pendingDeleteSource = nil } }), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let source = pendingDeleteSource { viewModel.deleteSource(source) }
                pendingDeleteSource = nil
            }
        } message: {
            Text("Its stored password or community is removed from the Keychain. Devices it found stay in the list.")
        }
    }

    static func defaultPort(_ kind: NetworkSourceKind) -> Int {
        switch kind {
        case .snmp: 161
        case .dhcpMikroTik: 443
        case .dhcpSSH, .dhcpImport: 0
        }
    }

    // MARK: Subnets

    private var subnetsSection: some View {
        Section {
            if viewModel.subnets.isEmpty {
                Text("No subnets yet. Add the ones you manage; only those are ever scanned.").foregroundStyle(.secondary)
            }
            // Rows are keyed by kind as well as id: a subnet and a source can
            // share an id, and one List would then reuse a subnet's row for
            // the source.
            ForEach(viewModel.subnets, id: \.cidr) { subnet in
                SubnetRow(subnet: subnet)
                    .contextMenu {
                        Button("Edit…") { editingSubnet = subnet }
                        if subnet.scanEnabled, let id = subnet.id { Button("Scan Now") { viewModel.scan(subnetID: id) } }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeleteSubnet = subnet }
                    }
                    .onTapGesture(count: 2) { editingSubnet = subnet }
            }
            // A row rather than the section's footer, which this list style
            // cuts to one line.
            Text("A subnet this Mac is on is scanned directly and finds every device, even ones that block ping. Others are pinged through the router; add the router over SNMP to see their MAC addresses.")
                .font(.caption).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } header: {
            Text("Subnets")
        }
    }

    private var suggestionsSection: some View {
        Section("Suggested") {
            ForEach(viewModel.localSuggestions, id: \.self) { network in
                suggestionRow(network, origin: AppLocale.string("This Mac is on it"))
            }
            ForEach(suggestions, id: \.self) { network in
                suggestionRow(network, origin: suggestionSource ?? "")
            }
        }
    }

    private func suggestionRow(_ network: IPv4CIDR, origin: String) -> some View {
        HStack {
            Text(network.description).monospacedDigit()
            Text(origin).foregroundStyle(.secondary)
            Spacer()
            Button("Add") {
                if viewModel.save(NetworkSubnet(name: network.description, cidr: network.description)) {
                    suggestions.removeAll { $0 == network }
                }
            }
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            if viewModel.sources.isEmpty {
                Text("No sources yet. A router read over SNMP shows the devices of every VLAN it routes, with their MAC addresses; a DHCP server shows who was given which address.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.sources, id: \.keychainRef) { source in
                SourceRow(source: source, onOpen: { if let id = source.id { navigationPath.append(id) } })
                    .contextMenu {
                        Button("Edit…") { editingSource = source }
                        if source.kind == .dhcpImport {
                            Button("Import File…") { viewModel.importLeases(into: source) }
                        } else if let id = source.id {
                            Button("Read Now") { viewModel.poll(sourceID: id) }
                            Button("Test Connection") { viewModel.test(source) }
                        }
                        if source.kind == .snmp {
                            Button("Find Its Subnets") {
                                Task {
                                    let local = viewModel.localSuggestions
                                    suggestions = await viewModel.detectSubnets(source).filter { !local.contains($0) }
                                    suggestionSource = source.name
                                    if suggestions.isEmpty { viewModel.infoMessage = AppLocale.string("No new subnets found on \(source.name).") }
                                }
                            }
                        }
                        if source.kind == .dhcpMikroTik, source.tlsFingerprint != nil {
                            Button("Trust Its Current Certificate") { viewModel.trustCertificateAgain(source) }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDeleteSource = source }
                    }
            }
        } header: {
            Text("Routers, switches and DHCP")
        }
    }
}

private struct SubnetRow: View {
    let subnet: NetworkSubnet
    @Bindable private var viewModel = NetworkViewModel.shared

    var body: some View {
        let id = subnet.id ?? -1
        let devices = viewModel.devices.filter { $0.subnetID == id }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(subnet.name).font(.headline)
                    Text(subnet.cidr).foregroundStyle(.secondary).monospacedDigit()
                    if let vlan = subnet.vlanID { Text(verbatim: "VLAN \(vlan)").foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    Text("\(devices.filter { $0.state == .online }.count) online of \(devices.count)")
                    Text(verbatim: "·")
                    coverage
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.scanningSubnetIDs.contains(id) {
                ProgressView().controlSize(.small)
                Button("Cancel") { viewModel.cancelScan(subnetID: id) }
            } else if subnet.scanEnabled {
                Button("Scan Now") { viewModel.scan(subnetID: id) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var coverage: some View {
        if !subnet.scanEnabled {
            Text("Not scanned from this Mac")
        } else if let status = subnet.lastScanStatus {
            HStack(spacing: 4) {
                if status == .localNetworkDenied {
                    Button("Local Network access is off: allow it…") { NetworkPermission.openSettings() }.buttonStyle(.link)
                } else {
                    Text(status.label)
                    if status == .completed, let mode = subnet.lastScanMode {
                        Text(mode == .direct ? "directly" : "through the router")
                    }
                }
                if let last = subnet.lastScanAt { Text(last, format: .relative(presentation: .named)) }
            }
        } else {
            Text("Not scanned yet")
        }
    }
}

private struct SourceRow: View {
    let source: NetworkSource
    let onOpen: () -> Void
    @Bindable private var viewModel = NetworkViewModel.shared

    var body: some View {
        let id = source.id ?? -1
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: source.kind.systemImage).font(.title3).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline)
                    Text(source.kind.label).foregroundStyle(.secondary)
                    if !source.enabled { Text("Paused").foregroundStyle(.orange) }
                }
                Group {
                    if let message = viewModel.sourceMessages[id] {
                        Text(message)
                    } else if let error = source.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let success = source.lastSuccessAt {
                        HStack(spacing: 4) {
                            Text("Read")
                            Text(success, format: .relative(presentation: .named))
                            if let name = source.sysName { Text(verbatim: "· \(name)") }
                        }
                    } else {
                        Text(source.kind == .dhcpImport ? "No file imported yet" : "Not read yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            if viewModel.pollingSourceIDs.contains(id) || viewModel.testingSourceIDs.contains(id) {
                ProgressView().controlSize(.small)
            } else if source.kind == .dhcpImport {
                Button("Import File…") { viewModel.importLeases(into: source) }
            } else {
                Button("Read Now") { viewModel.poll(sourceID: id) }
            }
            if source.kind == .snmp, source.snmpRoles.contains(.interfaces) {
                Button("Interfaces", action: onOpen)
            }
        }
        .padding(.vertical, 4)
    }
}

/// An SNMP device's interfaces: status, speed and traffic.
struct NetworkSourceDetailView: View {
    let sourceID: Int64
    @Bindable private var viewModel = NetworkViewModel.shared
    @State private var interfaces: [NetworkSNMPInterface] = []
    @State private var selectedInterface: Int?
    @State private var showsDownInterfaces = false

    private var source: NetworkSource? { viewModel.source(id: sourceID) }

    var body: some View {
        Form {
            if let source {
                Section {
                    LabeledContent("Address", value: "\(source.host):\(source.port)")
                    if let name = source.sysName { LabeledContent("Name", value: name) }
                    if let description = source.sysDescr {
                        LabeledContent("System") { Text(description).lineLimit(3).multilineTextAlignment(.trailing) }
                    }
                    if let success = source.lastSuccessAt {
                        LabeledContent("Read") { Text(success, format: .relative(presentation: .named)) }
                    }
                    if let error = source.lastError {
                        LabeledContent("Last error") { Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing) }
                    }
                }
            }
            if let index = selectedInterface, let interface = interfaces.first(where: { $0.ifIndex == index }) {
                Section(interface.name) { trafficChart(interface) }
            }
            Section {
                Toggle("Show interfaces that are down", isOn: $showsDownInterfaces)
                // Only interfaces reported down are hidden; a device that
                // doesn't report status at all still lists its interfaces.
                ForEach(interfaces.filter { showsDownInterfaces || $0.operStatus != 2 }) { interface in
                    Button {
                        selectedInterface = interface.ifIndex
                    } label: {
                        HStack {
                            Circle().fill(interface.isUp ? Color.green : interface.operStatus == nil ? Color.secondary : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(interface.name)
                                if let alias = interface.alias { Text(alias).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let speed = interface.speedMbps, speed > 0 {
                                Text(formatBitRate(Double(speed) * 1_000_000)).foregroundStyle(.secondary)
                            }
                            Text(verbatim: "↓ \(formatBitRate(interface.inBps))  ↑ \(formatBitRate(interface.outBps))")
                                .monospacedDigit()
                                .frame(minWidth: 190, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Interfaces")
            } footer: {
                Text("Rates are averaged between two readings. Click an interface for its last 24 hours.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(source?.name ?? "")
        .onAppear { interfaces = viewModel.interfaces(sourceID: sourceID) }
        .onChange(of: source?.lastSuccessAt) { _, _ in interfaces = viewModel.interfaces(sourceID: sourceID) }
    }

    private func trafficChart(_ interface: NetworkSNMPInterface) -> some View {
        let samples = viewModel.samples(sourceID: sourceID, ifIndex: interface.ifIndex)
        return Group {
            if samples.count < 2 {
                Text("Not enough readings yet.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(samples, id: \.sampledAt) { sample in
                        LineMark(x: .value("Time", sample.sampledAt), y: .value("bps", sample.inBps), series: .value("Direction", "In"))
                            .foregroundStyle(by: .value("Direction", AppLocale.string("In")))
                        LineMark(x: .value("Time", sample.sampledAt), y: .value("bps", sample.outBps), series: .value("Direction", "Out"))
                            .foregroundStyle(by: .value("Direction", AppLocale.string("Out")))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let bps = value.as(Double.self) { Text(formatBitRate(bps)) } }
                    }
                }
                .frame(height: 180)
            }
        }
    }
}
