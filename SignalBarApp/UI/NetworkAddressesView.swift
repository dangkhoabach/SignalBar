import SignalBarCore
import SwiftUI

/// Network › IP Addresses: every address of a subnet, coloured by what is
/// known about it, and who holds it.
struct NetworkAddressesView: View {
    @Bindable private var viewModel = NetworkViewModel.shared
    @State private var subnetID: Int64?
    @State private var navigationPath = NavigationPath()
    @State private var showsList = false
    @State private var isAddingSubnet = false

    private var subnet: NetworkSubnet? {
        subnetID.flatMap { viewModel.subnet(id: $0) } ?? viewModel.subnets.first
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let subnet {
                    page(subnet)
                } else {
                    NetworkEmptyState(onAdd: { isAddingSubnet = true })
                }
            }
            .navigationTitle("IP Addresses")
            .navigationDestination(for: Int64.self) { NetworkDeviceDetailView(deviceID: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Picker("Subnet", selection: Binding(get: { subnet?.id }, set: { subnetID = $0 })) {
                        ForEach(viewModel.subnets) { item in
                            Text(verbatim: "\(item.name) (\(item.cidr))").tag(item.id)
                        }
                    }
                    .fixedSize()
                    .disabled(viewModel.subnets.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $showsList) {
                        Label("Map", systemImage: "square.grid.3x3").tag(false)
                        Label("List", systemImage: "list.bullet").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $isAddingSubnet) { NetworkSubnetFormView(subnet: nil) }
        .networkAlerts(viewModel)
    }

    private func page(_ subnet: NetworkSubnet) -> some View {
        let rows = viewModel.addresses(of: subnet)
        let counts = Dictionary(grouping: rows, by: \.state).mapValues(\.count)
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                ForEach(NetworkViewModel.AddressState.allCases, id: \.self) { state in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(state.color).frame(width: 12, height: 12)
                        Text(state.label)
                        Text(counts[state] ?? 0, format: .number).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            if showsList {
                list(rows.filter { $0.state != .unknown && $0.state != .free })
            } else {
                map(rows, showsThirdOctet: (subnet.network?.prefixLength ?? 24) < 24)
            }
            Divider()
            Text(footnote(subnet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private func footnote(_ subnet: NetworkSubnet) -> LocalizedStringKey {
        if subnet.lastScanMode == .direct {
            return "Free means nothing answered on this Mac's own network at the last scan. A device that is switched off looks the same, so check before handing out an address by hand."
        }
        return "This Mac can't see this subnet's link, so an address nobody reports is shown as unknown rather than free."
    }

    /// Each cell shows the last octet; on a subnet wider than /24 the last
    /// two, since the last alone repeats.
    private func map(_ rows: [NetworkViewModel.AddressRow], showsThirdOctet: Bool) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: showsThirdOctet ? 58 : 46, maximum: 72), spacing: 4)], spacing: 4) {
                ForEach(rows) { row in
                    Button {
                        if let id = row.device?.id { navigationPath.append(id) }
                    } label: {
                        Text(verbatim: showsThirdOctet
                             ? "\(row.address.value >> 8 & 0xFF).\(row.address.value & 0xFF)" : String(row.address.value & 0xFF))
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(row.state.color, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(row.state == .unknown || row.state == .free ? Color.secondary : Color.white)
                    }
                    .buttonStyle(.plain)
                    .help(tooltip(row))
                }
            }
            .padding(16)
        }
    }

    private func tooltip(_ row: NetworkViewModel.AddressRow) -> String {
        var lines = [row.address.description]
        if let device = row.device {
            lines.append(device.name)
            if let mac = device.mac { lines.append(mac) }
            if let vendor = device.vendor { lines.append(vendor) }
        } else if let lease = row.lease {
            lines.append(lease.hostname ?? lease.mac)
        }
        return lines.joined(separator: "\n")
    }

    private func list(_ rows: [NetworkViewModel.AddressRow]) -> some View {
        Table(rows) {
            TableColumn("IP") { Text($0.address.description).monospacedDigit() }.width(min: 100, ideal: 120)
            TableColumn("State") { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(row.state.color).frame(width: 10, height: 10)
                    Text(row.state.label)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Device") { row in
                if let device = row.device, let id = device.id {
                    Button(device.name) { navigationPath.append(id) }.buttonStyle(.link)
                } else {
                    Text(row.lease?.hostname ?? "—").foregroundStyle(.secondary)
                }
            }
            TableColumn("MAC") { Text($0.device?.mac ?? $0.lease?.mac ?? "—").font(.system(.body, design: .monospaced)) }
            TableColumn("Source") { row in
                if row.lease?.isReserved == true {
                    Text("DHCP reservation")
                } else if row.lease != nil {
                    Text("DHCP lease")
                } else if let source = row.device?.hostnameSource, row.device?.lastSeenAt == nil {
                    Text(source.label)
                } else if row.device != nil {
                    Text("Seen on the network")
                } else {
                    Text("—")
                }
            }
            TableColumn("Last seen") { row in
                if let seen = row.device?.lastSeenAt {
                    Text(seen, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
    }
}
