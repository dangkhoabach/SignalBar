import AppKit
import Charts
import SignalBarCore
import SwiftUI

/// Network › Connection: how this Mac reaches the internet.
struct ConnectionView: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionHeader()
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) { InternetCard(); DNSCard(); VPNProxyCard() }
                            VStack(spacing: 16) { ThisMacCard(); if model.wifi != nil { WiFiCard() } }
                        }
                        .frame(minWidth: 720)
                        VStack(spacing: 16) {
                            InternetCard(); ThisMacCard()
                            if model.wifi != nil { WiFiCard() }
                            DNSCard(); VPNProxyCard()
                        }
                    }
                    QualityCard()
                    PublicIPHistoryCard()
                }
                .padding(20)
            }
            .modifier(HardTopScrollEdge())
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem {
                    if model.status.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .help("Read everything again")
                    }
                }
            }
        }
        .onAppear { model.startLive() }
        .onDisappear { model.stopLive() }
    }
}

// MARK: - Building blocks

/// Without it, cards scrolled under the toolbar show through the window title.
private struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// The chart colours, in fixed order: the first three categorical slots,
/// each stepped for light and dark (checked for colour-blind separation).
enum ConnectionChartColor {
    static let first = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let second = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let third = dynamic(light: 0x1BAF7A, dark: 0x199E70)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct ConnectionCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Label(title, systemImage: systemImage).font(.headline)
        }
    }
}

/// A label, its value, and a copy button for values worth pasting elsewhere.
struct ConnectionRow<Value: View>: View {
    let label: LocalizedStringKey
    var copyText: String?
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
            value.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let copyText {
                Button { ConnectionViewModel.copy(copyText) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy")
            }
        }
    }
}

extension ConnectionRow where Value == AnyView {
    /// A plain text value; "—" when there is none.
    init(_ label: LocalizedStringKey, _ text: String?, copy: Bool = false, monospaced: Bool = false) {
        self.label = label
        self.copyText = copy ? text : nil
        let shown = Text(verbatim: text ?? "—")
        self.value = AnyView(shown.font(monospaced ? .body.monospacedDigit() : .body).foregroundStyle(text == nil ? .secondary : .primary))
    }
}

struct ConnectionTag: View {
    let text: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

private func formatMilliseconds(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
}

private func countryName(_ code: String) -> String {
    let flag = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    let name = AppLocale.selected.locale.localizedString(forRegionCode: code) ?? code
    return "\(flag) \(name)"
}

// MARK: - Header

private struct ConnectionHeader: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    if let via = viaText { Text(verbatim: via).foregroundStyle(.secondary) }
                    tags
                }
            }
            Spacer()
            if let refreshed = model.status.refreshedAt {
                Text("Updated \(refreshed, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch model.reachability {
        case .checking: "Checking the connection…"
        case .online: "Connected to the internet"
        case .noInternet: "Connected, but the internet can't be reached"
        case .offline: "Not connected"
        }
    }

    private var icon: String {
        switch model.reachability {
        case .checking: "ellipsis.circle"
        case .online: "checkmark.circle.fill"
        case .noInternet: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        }
    }

    private var tint: Color {
        switch model.reachability {
        case .checking: .secondary
        case .online: .green
        case .noInternet: .orange
        case .offline: .red
        }
    }

    private var viaText: String? {
        guard let primary = model.status.local.primary else { return nil }
        let kind: String? = switch model.status.path?.kind {
        case .wifi: AppLocale.string("Wi-Fi")
        case .ethernet: AppLocale.string("Ethernet")
        case .cellular: AppLocale.string("Cellular")
        default: primary.serviceName
        }
        return [kind, primary.name].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var tags: some View {
        let status = model.status
        if !status.local.tunnels.isEmpty { ConnectionTag(text: "VPN", systemImage: "lock.fill", tint: .accentColor) }
        if status.local.proxies.isActive { ConnectionTag(text: "Proxy", systemImage: "arrow.triangle.branch", tint: .accentColor) }
        if status.path?.isExpensive == true { ConnectionTag(text: "Metered", systemImage: "dollarsign.circle") }
        if status.path?.isConstrained == true { ConnectionTag(text: "Low Data Mode", systemImage: "tortoise") }
        if status.local.primary != nil {
            if status.local.primary?.ipv6.contains(where: { $0.kind != .linkLocal }) == true {
                ConnectionTag(text: "IPv6")
            } else {
                ConnectionTag(text: "IPv4 only")
            }
        }
    }
}

// MARK: - Internet

private struct InternetCard: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        ConnectionCard(title: "Internet", systemImage: "globe") {
            let status = model.status
            if !status.lookupEnabled {
                Text("Looking up the public address is off. Turn it on in Settings › Network to see it here.")
                    .foregroundStyle(.secondary)
            } else if status.refreshedAt != nil, status.publicIPv4 == nil, status.publicIPv6 == nil, !status.isRefreshing {
                Label("Couldn't reach Cloudflare or OpenDNS to find the public address.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if status.lookupEnabled {
                ConnectionRow("Public IPv4", status.publicIPv4?.ip, copy: true, monospaced: true)
                ConnectionRow("Public IPv6", status.publicIPv6?.ip ?? (status.refreshedAt == nil ? nil : AppLocale.string("None found")),
                              copy: status.publicIPv6 != nil, monospaced: true)
                let address = status.publicIPv4 ?? status.publicIPv6
                ConnectionRow("Provider", address.flatMap(providerText))
                if let country = address?.country {
                    ConnectionRow("Country", countryName(country))
                }
                if let colo = address?.colo {
                    ConnectionRow(label: "Cloudflare edge") {
                        HStack(spacing: 6) {
                            Text(verbatim: colo)
                            if address?.warp == true { ConnectionTag(text: "WARP", tint: .accentColor) }
                        }
                    }
                }
                if let name = address?.reverseName { ConnectionRow("Reverse DNS", name, copy: true) }
                if let since = currentSince { ConnectionRow(label: "Since") { Text(since, format: .dateTime.day().month().hour().minute()) } }
            }
            ConnectionRow(label: "NAT") { natView }
        }
    }

    private func providerText(_ address: PublicAddress) -> String? {
        guard let holder = address.holder else { return nil }
        return address.asn.map { "\(holder) (AS\($0))" } ?? holder
    }

    /// When the current IPv4 (or IPv6) address was first seen.
    private var currentSince: Date? {
        guard let ip = model.primaryPublicIP else { return nil }
        return model.history.first { $0.ip == ip }?.firstSeenAt
    }

    @ViewBuilder
    private var natView: some View {
        let hop = model.status.providerHop?.description ?? ""
        switch model.status.natLayout {
        case .single:
            Text("One NAT: the router has a public address")
        case .double:
            VStack(alignment: .leading, spacing: 2) {
                Label("Double NAT: another router is in front of yours", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The hop after your router is \(hop), a private address. Port forwarding must be set on both.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .carrierGrade:
            VStack(alignment: .leading, spacing: 2) {
                Label("Carrier-grade NAT: the provider shares one address", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The hop after your router is \(hop). Connections from the internet can't reach this network; ask the provider for a public IP.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unknown:
            Text(model.status.local.vpnCarriesAllTraffic ? "Unknown while all traffic goes through a VPN" : "Unknown: the hops past the router didn't answer")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - This Mac

private struct ThisMacCard: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        ConnectionCard(title: "This Mac", systemImage: "laptopcomputer") {
            if let primary = model.status.local.primary {
                ConnectionRow("Interface", [primary.serviceName, primary.name].compactMap { $0 }.joined(separator: " · "))
                ConnectionRow("IPv4", primary.ipv4.map { "\($0)/\(primary.ipv4Prefix ?? 32)" }, copy: true, monospaced: true)
                ConnectionRow("Subnet mask", primary.subnetMask?.description, monospaced: true)
                ConnectionRow("Router", primary.router, copy: true, monospaced: true)
                ipv6Rows(primary)
                ConnectionRow(label: "MAC address") {
                    HStack(spacing: 6) {
                        Text(verbatim: primary.mac?.description ?? "—").font(.body.monospaced())
                        if primary.mac?.isLocallyAdministered == true {
                            ConnectionTag(text: "Private", systemImage: "lock.shield")
                                .help("A private Wi-Fi address: this Mac shows this network a made-up hardware address")
                        }
                    }
                }
                ConnectionRow("MTU", primary.mtu.map { "\($0)" })
                if model.status.path?.kind != .wifi, let speed = primary.linkSpeedBitsPerSecond {
                    ConnectionRow("Link speed", formatBitRate(Double(speed)))
                }
                if let dhcp = primary.dhcp { dhcpRows(dhcp) }
            } else {
                Text("No network interface is connected.").foregroundStyle(.secondary)
            }
            if !model.status.local.others.isEmpty {
                Divider()
                ForEach(model.status.local.others, id: \.name) { other in
                    ConnectionRow(LocalizedStringKey(other.serviceName ?? other.name),
                                  other.ipv4.map { "\($0)/\(other.ipv4Prefix ?? 32)" }, copy: true, monospaced: true)
                }
            }
        }
    }

    @ViewBuilder
    private func ipv6Rows(_ primary: InterfaceDetails) -> some View {
        let global = primary.ipv6.filter { $0.kind != .linkLocal }
        if global.isEmpty {
            ConnectionRow("IPv6", primary.ipv6.isEmpty ? nil : AppLocale.string("Link-local only"))
        }
        ForEach(global, id: \.address) { entry in
            ConnectionRow(label: entry.kind == .temporary ? "IPv6 (temporary)" : "IPv6", copyText: entry.address) {
                Text(verbatim: "\(entry.address)/\(entry.prefixLength)").font(.body.monospacedDigit())
            }
        }
        if let router = primary.ipv6Router, !global.isEmpty { ConnectionRow("IPv6 router", router, monospaced: true) }
    }

    @ViewBuilder
    private func dhcpRows(_ dhcp: DHCPLeaseInfo) -> some View {
        ConnectionRow("DHCP server", dhcp.server, monospaced: true)
        if let end = dhcp.leaseEnd {
            ConnectionRow(label: "Lease") {
                if let start = dhcp.leaseStart {
                    Text("\(start, format: .dateTime.day().month().hour().minute()) – \(end, format: .dateTime.day().month().hour().minute())")
                } else {
                    Text("Until \(end, format: .dateTime.day().month().hour().minute())")
                }
            }
        }
        if let domain = dhcp.domainName { ConnectionRow("Domain", domain) }
    }
}

// MARK: - Wi-Fi

private struct WiFiCard: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        ConnectionCard(title: "Wi-Fi", systemImage: "wifi") {
            if let wifi = model.wifi {
                ConnectionRow(label: "Network") { networkName(wifi) }
                if let bssid = wifi.bssid { ConnectionRow("Access point", bssid, copy: true, monospaced: true) }
                ConnectionRow(label: "Signal") {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(wifi.rssi) dBm · \(AppLocale.string("noise")) \(wifi.noise) dBm · SNR \(wifi.snr) dB")
                            .monospacedDigit()
                        qualityTag(wifi.quality)
                    }
                }
                ConnectionRow("Channel", channelText(wifi))
                ConnectionRow("Standard", [wifi.generation, wifi.standard.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                ConnectionRow("Transmit rate", String(format: "%.0f Mbps", wifi.transmitRateMbps))
                ConnectionRow(label: "Security") {
                    if let security = wifi.security, security == "Open" || security == "WEP" {
                        Label(security == "Open" ? AppLocale.string("Open (not encrypted)") : security, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text(verbatim: wifi.security ?? "—")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkName(_ wifi: WiFiStatus) -> some View {
        if let ssid = wifi.ssid {
            Text(verbatim: ssid)
        } else {
            switch model.wifiNameAccess.state {
            case .granted:
                Text("—").foregroundStyle(.secondary)
            case .notAsked:
                Button("Show Network Name…") { model.wifiNameAccess.request() }
                    .help("macOS shows the Wi-Fi network's name only to apps with Location access")
            case .denied:
                HStack(spacing: 6) {
                    Text("Needs Location access").foregroundStyle(.secondary)
                    Button("Open Settings…") { model.wifiNameAccess.request() }
                }
            }
        }
    }

    private func channelText(_ wifi: WiFiStatus) -> String {
        let band: String? = switch wifi.band {
        case .ghz2: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        case nil: nil
        }
        let details = [band, wifi.channelWidthMHz.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: ", ")
        guard let channel = wifi.channel else { return details }
        return details.isEmpty ? "\(channel)" : "\(channel) (\(details))"
    }

    private func qualityTag(_ quality: WiFiStatus.Quality) -> some View {
        switch quality {
        case .excellent: ConnectionTag(text: "Excellent", tint: .green)
        case .good: ConnectionTag(text: "Good", tint: .green)
        case .fair: ConnectionTag(text: "Fair", tint: .orange)
        case .poor: ConnectionTag(text: "Poor", tint: .red)
        }
    }
}

// MARK: - DNS

private struct DNSCard: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        ConnectionCard(title: "DNS", systemImage: "character.book.closed") {
            let dns = model.status.local.dns
            ConnectionRow(label: "Servers") {
                VStack(alignment: .leading, spacing: 2) {
                    if dns.servers.isEmpty { Text("—").foregroundStyle(.secondary) }
                    ForEach(dns.servers, id: \.self) { server in
                        HStack(spacing: 6) {
                            Text(verbatim: server).font(.body.monospacedDigit())
                            if let timing = model.status.dnsTimings.first(where: { $0.server == server }) {
                                Text(verbatim: formatMilliseconds(timing.milliseconds)).font(.caption).foregroundStyle(.secondary)
                                    .help(timing.milliseconds == nil ? "Didn't answer a lookup sent straight to it" : "Time to answer a lookup sent straight to it")
                            }
                        }
                    }
                }
            }
            ConnectionRow(label: "Set by") {
                switch dns.source {
                case .manual: Text("Typed in System Settings")
                case .vpn: Text("The VPN")
                case .network: Text("The network (DHCP)")
                }
            }
            if !dns.offeredByNetwork.isEmpty {
                ConnectionRow("Network offers", dns.offeredByNetwork.joined(separator: ", "), monospaced: true)
            }
            if !dns.searchDomains.isEmpty { ConnectionRow("Search domains", dns.searchDomains.joined(separator: ", ")) }
            ForEach(dns.scoped, id: \.domains) { scoped in
                ConnectionRow(label: "Split DNS") {
                    Text(verbatim: "\(scoped.domains.joined(separator: ", ")) → \(scoped.servers.joined(separator: ", "))")
                }
            }
            if let egress = model.status.dnsEgress {
                ConnectionRow(label: "Leaves through") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: [egress.ip, egress.holder].compactMap { $0 }.joined(separator: " · "))
                        Text("The resolver that finally asks the internet for you")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - VPN and proxy

private struct VPNProxyCard: View {
    @Bindable private var model = ConnectionViewModel.shared

    var body: some View {
        ConnectionCard(title: "VPN & Proxy", systemImage: "lock.shield") {
            let local = model.status.local
            if local.tunnels.isEmpty {
                ConnectionRow("VPN", AppLocale.string("Not in use"))
            } else {
                ForEach(local.tunnels, id: \.name) { tunnel in
                    ConnectionRow(label: "VPN") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: tunnelName(tunnel))
                            Text(verbatim: tunnel.addresses.joined(separator: ", ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                ConnectionRow(label: "Traffic") {
                    Text(local.vpnCarriesAllTraffic ? "Everything goes through the VPN" : "Only some networks go through the VPN")
                }
            }
            let proxies = local.proxies
            if !proxies.isActive {
                ConnectionRow("Proxy", AppLocale.string("Not in use"))
            } else {
                if let http = proxies.http { ConnectionRow("HTTP proxy", http, copy: true) }
                if let https = proxies.https { ConnectionRow("HTTPS proxy", https, copy: true) }
                if let socks = proxies.socks { ConnectionRow("SOCKS proxy", socks, copy: true) }
                if let pac = proxies.autoConfigURL { ConnectionRow("Auto-config (PAC)", pac, copy: true) }
                if proxies.autoDiscovery { ConnectionRow("Auto-discovery", AppLocale.string("On")) }
                if !proxies.exceptions.isEmpty { ConnectionRow("Bypassed for", proxies.exceptions.joined(separator: ", ")) }
            }
        }
    }

    private func tunnelName(_ tunnel: VPNTunnel) -> String {
        let name = tunnel.serviceName ?? (tunnel.looksLikeTailscale ? "Tailscale" : nil)
        return [name, tunnel.name].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Quality

private struct QualityCard: View {
    @Bindable private var model = ConnectionViewModel.shared
    @State private var latencySelection: Date?
    @State private var throughputSelection: Date?

    var body: some View {
        ConnectionCard(title: "Connection Quality", systemImage: "waveform.path.ecg") {
            HStack(alignment: .top, spacing: 12) {
                stats("Router", subtitle: model.status.local.primary?.router, model.gatewayStats, color: ConnectionChartColor.first)
                stats("Provider", subtitle: model.status.providerHop?.description, model.providerStats, color: ConnectionChartColor.second)
                stats("Internet", subtitle: "1.1.1.1", model.internetStats, color: ConnectionChartColor.third)
            }
            verdict
            if model.latency.count >= 2 {
                latencyChart
            }
            if model.throughput.count >= 2 {
                throughputChart
            }
            Text("Measured every few seconds while this page is open; the last 10 minutes are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stats(_ title: LocalizedStringKey, subtitle: String?, _ stats: ConnectionViewModel.LatencyStats, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(verbatim: subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text(verbatim: formatMilliseconds(stats.average)).font(.title3.weight(.semibold).monospacedDigit())
            Text("Jitter \(formatMilliseconds(stats.jitter)) · Loss \(stats.lossPercent, format: .number.precision(.fractionLength(0)))%")
                .font(.caption)
                .foregroundStyle(stats.lossPercent >= 5 ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var verdict: some View {
        switch model.slowStretch {
        case .localNetwork:
            Label("Slow before the router: the Wi-Fi or the local network is the problem.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .provider:
            Label("Slow at the provider: the router answers quickly, the provider's network doesn't.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .beyond:
            Label("Slow past the provider: the local network and the provider answer quickly.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case nil:
            if model.latency.count >= 3, model.internetStats.average != nil {
                Label("Latency is normal all the way out.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var seriesScale: KeyValuePairs<String, Color> {
        [AppLocale.string("Router"): ConnectionChartColor.first,
         AppLocale.string("Provider"): ConnectionChartColor.second,
         AppLocale.string("Internet"): ConnectionChartColor.third]
    }

    private var latencyChart: some View {
        let series: [(String, KeyPath<ConnectionViewModel.LatencySample, Double?>)] = [
            (AppLocale.string("Router"), \.gateway), (AppLocale.string("Provider"), \.provider), (AppLocale.string("Internet"), \.internet),
        ]
        let selected = latencySelection.flatMap { date in model.latency.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Latency").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(series, id: \.0) { name, keyPath in
                    ForEach(model.latency) { sample in
                        if let value = sample[keyPath: keyPath] {
                            LineMark(x: .value("Time", sample.date), y: .value("ms", value), series: .value("Target", name))
                                .foregroundStyle(by: .value("Target", name))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(selected.date, rows: series.map { ($0.0, formatMilliseconds(selected[keyPath: $0.1])) })
                        }
                }
            }
            .chartForegroundStyleScale(seriesScale)
            .chartXSelection(value: $latencySelection)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let ms = value.as(Double.self) { Text(verbatim: "\(Int(ms)) ms") } }
                }
            }
            .frame(height: 160)
        }
    }

    private var throughputChart: some View {
        let inName = AppLocale.string("Download")
        let outName = AppLocale.string("Upload")
        let selected = throughputSelection.flatMap { date in
            model.throughput.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Traffic on \(model.status.local.primary?.name ?? "")").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(model.throughput) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("bps", sample.inBitsPerSecond), series: .value("Direction", inName))
                        .foregroundStyle(by: .value("Direction", inName))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(x: .value("Time", sample.date), y: .value("bps", sample.outBitsPerSecond), series: .value("Direction", outName))
                        .foregroundStyle(by: .value("Direction", outName))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let selected {
                    RuleMark(x: .value("Time", selected.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(selected.date, rows: [(inName, formatBitRate(selected.inBitsPerSecond)),
                                                          (outName, formatBitRate(selected.outBitsPerSecond))])
                        }
                }
            }
            .chartForegroundStyleScale([inName: ConnectionChartColor.first, outName: ConnectionChartColor.second])
            .chartXSelection(value: $throughputSelection)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let bps = value.as(Double.self) { Text(verbatim: formatBitRate(bps)) } }
                }
            }
            .frame(height: 140)
        }
    }

    private func tooltip(_ date: Date, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { name, value in
                HStack(spacing: 6) {
                    Text(verbatim: name).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(verbatim: value).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(6)
        .frame(minWidth: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - History

private struct PublicIPHistoryCard: View {
    @Bindable private var model = ConnectionViewModel.shared
    @State private var isConfirmingClear = false

    var body: some View {
        ConnectionCard(title: "Public IP History", systemImage: "clock.arrow.circlepath") {
            if model.history.isEmpty {
                Text(model.status.lookupEnabled ? "No addresses recorded yet." : "Nothing is recorded while the public address lookup is off.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Address"); Text("Provider"); Text("First seen"); Text("Last seen")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(model.history.prefix(30)) { record in
                        GridRow {
                            Text(verbatim: record.ip).font(.body.monospacedDigit()).textSelection(.enabled)
                            Text(verbatim: record.holder ?? "—").lineLimit(1)
                            Text(record.firstSeenAt, format: .dateTime.day().month().year().hour().minute())
                            Text(record.lastSeenAt, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }
                HStack {
                    Text("A new address is recorded when it changes; a notification can be turned on in Settings › Network.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                }
            }
        }
        .confirmationDialog("Clear the public IP history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        }
    }
}
