import SignalBarCore
import SwiftUI

/// Network › Devices: every device in the managed subnets, which address it
/// holds and how it was found.
struct NetworkDevicesView: View {
    @Bindable private var viewModel = NetworkViewModel.shared
    @Bindable private var navigationState = AppNavigationState.shared
    @State private var navigationPath = NavigationPath()
    @State private var isAddingSubnet = false
    @State private var pendingDelete: Set<Int64> = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Devices")
                .navigationDestination(for: Int64.self) { NetworkDeviceDetailView(deviceID: $0) }
                .toolbar { toolbar }
        }
        .onAppear { viewModel.start() }
        .onChange(of: navigationState.pendingDeviceID) { _, id in
            guard let id else { return }
            navigationPath = NavigationPath([id])
            navigationState.pendingDeviceID = nil
        }
        .sheet(isPresented: $isAddingSubnet) { NetworkSubnetFormView(subnet: nil) }
        .networkAlerts(viewModel)
        .confirmationDialog(
            "Delete the selected devices?", isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteDevices(ids: pendingDelete)
                pendingDelete = []
            }
        } message: {
            Text("Their history goes too. A device that is still on the network will be found again by the next scan.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.subnets.isEmpty {
            NetworkEmptyState(onAdd: { isAddingSubnet = true })
        } else {
            VStack(spacing: 0) {
                NetworkSummaryStrip()
                Divider()
                if viewModel.devices.isEmpty {
                    ContentUnavailableView(
                        "No devices yet", systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Scan a subnet, or add a router, switch or DHCP server under Networks.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    table
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Ping, traceroute, a port check and Wake-on-LAN, opened in Tools with the device filled in.
    @ViewBuilder
    private func toolItems(_ device: NetworkDevice) -> some View {
        Menu("Tools") {
            if let ip = device.currentIP {
                Button("Ping") { AppNavigationState.shared.openTool(.ping, target: ip) }
                Button("Traceroute") { AppNavigationState.shared.openTool(.traceroute, target: ip) }
                Button("Check Ports…") { AppNavigationState.shared.openTool(.ports, target: ip) }
            }
            if let mac = device.mac, !device.hasPrivateMAC {
                Button("Wake…") { AppNavigationState.shared.openTool(.wake, target: mac) }
            }
        }
    }

    private var table: some View {
        Table(viewModel.filteredRows, selection: $viewModel.selection, sortOrder: $viewModel.sortOrder) {
            TableColumn("Status", value: \.statusRank) { NetworkStatusLabel(row: $0) }
                .width(min: 80, ideal: 90)
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.device.deviceType.systemImage).foregroundStyle(.secondary).frame(width: 16)
                    Text(row.name).lineLimit(1)
                    if row.isNew {
                        Text("New").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
                    }
                    if row.device.isWatched {
                        Image(systemName: "eye").font(.caption).foregroundStyle(.secondary).help("Watched")
                    }
                }
            }
            .width(min: 150, ideal: 190)
            TableColumn("IP", value: \.ipSortKey) { Text($0.device.currentIP ?? "—").monospacedDigit() }
                .width(min: 100, ideal: 115)
            TableColumn("MAC", value: \.macText) { row in
                HStack(spacing: 4) {
                    if let mac = row.device.mac {
                        Text(mac).font(.system(.body, design: .monospaced)).lineLimit(1)
                    } else {
                        Text(verbatim: "—").foregroundStyle(.secondary)
                            .help("macOS doesn't give apps the MAC addresses of other devices. Add the router over SNMP, or a DHCP server, to see them.")
                    }
                    if row.device.hasPrivateMAC {
                        Image(systemName: "lock.shield").font(.caption).foregroundStyle(.secondary)
                            .help("Private address: the device hides its hardware address, and may change it")
                    }
                }
            }
            .width(min: 150, ideal: 185)
            TableColumn("Manufacturer", value: \.vendorText) { Text($0.device.vendor ?? "").lineLimit(1) }
                .width(min: 90, ideal: 150)
            TableColumn("Network", value: \.subnetText) { Text($0.subnetText).lineLimit(1) }
                .width(min: 90, ideal: 130)
            TableColumn("Last seen", value: \.lastSeenKey) { row in
                if let seen = row.device.lastSeenAt {
                    Text(seen, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Show Details") { navigationPath.append(id) }
                if let device = viewModel.devices.first(where: { $0.id == id }) {
                    toolItems(device)
                }
                Divider()
            }
            Button("Watch") { viewModel.setWatched(true, ids: ids) }
            Button("Stop Watching") { viewModel.setWatched(false, ids: ids) }
            Divider()
            Button("Hide from the List") { viewModel.setIgnored(true, ids: ids) }
            Button("Show in the List") { viewModel.setIgnored(false, ids: ids) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = ids }
        } primaryAction: { ids in
            if let id = ids.first { navigationPath.append(id) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Picker("Show", selection: $viewModel.filter) {
                    Text("All").tag(NetworkViewModel.DeviceFilter.all)
                    Text("Online").tag(NetworkViewModel.DeviceFilter.online)
                    Text("Offline").tag(NetworkViewModel.DeviceFilter.offline)
                    Text("Not seen").tag(NetworkViewModel.DeviceFilter.unknown)
                    Text("New today").tag(NetworkViewModel.DeviceFilter.new)
                    Text("Watched").tag(NetworkViewModel.DeviceFilter.watched)
                    Text("Conflicts").tag(NetworkViewModel.DeviceFilter.conflicts)
                    Text("Hidden").tag(NetworkViewModel.DeviceFilter.hidden)
                }
                .pickerStyle(.inline)
                Picker("Network", selection: $viewModel.subnetFilter) {
                    Text("All networks").tag(Int64?.none)
                    ForEach(viewModel.subnets) { subnet in
                        Text(verbatim: "\(subnet.name) (\(subnet.cidr))").tag(subnet.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: viewModel.filter == .all && viewModel.subnetFilter == nil
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }

            Button {
                viewModel.scanAll()
            } label: {
                if viewModel.scanningSubnetIDs.isEmpty {
                    Label("Scan All", systemImage: "arrow.clockwise")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .help("Scan every subnet this Mac scans")
            .disabled(viewModel.subnets.isEmpty || !viewModel.scanningSubnetIDs.isEmpty)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                viewModel.exportDevicesCSV()
            } label: {
                Label("Export CSV…", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.devices.isEmpty)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            NativeSearchField(text: $viewModel.searchText, placeholder: AppLocale.string("Search IP, MAC, name"))
                .frame(minWidth: 200)
        }
    }
}

/// The counts above the Devices and IP Addresses pages.
struct NetworkSummaryStrip: View {
    @Bindable private var viewModel = NetworkViewModel.shared
    @Bindable private var settings = SettingsViewModel.shared

    var body: some View {
        let summary = viewModel.summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 24) {
                NetworkStatChip(title: "Devices", value: summary.total)
                NetworkStatChip(title: "Online", value: summary.online, tint: .green)
                NetworkStatChip(title: "Offline", value: summary.offline, tint: summary.offline > 0 ? .red : .primary)
                NetworkStatChip(title: "New today", value: summary.new, tint: summary.new > 0 ? .accentColor : .primary)
                NetworkStatChip(title: "IP conflicts", value: summary.conflicts, tint: summary.conflicts > 0 ? .orange : .primary)
                Spacer(minLength: 12)
                Group {
                    if !viewModel.scanningSubnetIDs.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else if let last = viewModel.lastScanAt {
                        Text("Last scan \(last, format: .relative(presentation: .named))")
                    } else {
                        Text("Not scanned yet")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
            notices
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear { settings.loadIfNeeded() }
    }

    /// Lines under the counts for what keeps the list from being current.
    @ViewBuilder
    private var notices: some View {
        if viewModel.subnets.contains(where: { $0.lastScanStatus == .localNetworkDenied }) {
            Label {
                HStack(spacing: 4) {
                    Text("Local Network access is off, so scans of this Mac's network find nothing.")
                    Button("Allow…") { NetworkPermission.openSettings() }.buttonStyle(.link)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
        }
        // Scheduling is opt-in; without it the list only changes when a scan
        // is started by hand, which is easy to miss.
        if !settings.settings.networkMonitoringEnabled {
            Label {
                HStack(spacing: 4) {
                    Text("Automatic scans are off: the list changes only when you scan.")
                    Button("Turn On") {
                        settings.settings.networkMonitoringEnabled = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            await AppNetworkMonitor.shared?.tick()
                        }
                    }
                    .buttonStyle(.link)
                }
            } icon: {
                Image(systemName: "clock.badge.xmark").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

/// What the Network pages show before any subnet is added: the Mac's own
/// subnets one click away.
struct NetworkEmptyState: View {
    @Bindable private var viewModel = NetworkViewModel.shared
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No networks yet", systemImage: "point.3.filled.connected.trianglepath.dotted")
        } description: {
            Text("Add the subnets you manage. SignalBar finds the devices in them from this Mac, and from routers, switches and DHCP servers you add under Networks.")
        } actions: {
            ForEach(viewModel.localSuggestions, id: \.self) { network in
                Button("Add \(network.description) (this Mac's network)") {
                    viewModel.save(NetworkSubnet(name: AppLocale.string("Local network"), cidr: network.description))
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Add Subnet…", action: onAdd)
        }
    }
}

/// macOS's Local Network permission: where to turn it on, since an app can
/// neither read nor change it.
enum NetworkPermission {
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension View {
    /// The error and info alerts every Network page shows from the shared model.
    func networkAlerts(_ viewModel: NetworkViewModel) -> some View {
        self
            .alert("Error", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Network", isPresented: Binding(get: { viewModel.infoMessage != nil }, set: { if !$0 { viewModel.infoMessage = nil } })) {
                Button("OK", role: .cancel) { viewModel.infoMessage = nil }
            } message: {
                Text(viewModel.infoMessage ?? "")
            }
    }
}
