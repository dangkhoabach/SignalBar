import Charts
import SignalBarCore
import SwiftUI

/// Network › Tools: ping, traceroute, DNS, ports, whois, HTTP and Wake-on-LAN,
/// each run only when asked.
struct ToolsView: View {
    @Bindable private var model = ToolsViewModel.shared
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tool", selection: $model.tool) {
                    ForEach(NetworkTool.allCases) { tool in Text(verbatim: AppLocale.string(tool.title)).tag(tool) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                Group {
                    switch model.tool {
                    case .ping: PingToolView()
                    case .traceroute: TraceToolView()
                    case .dns: DNSToolView()
                    case .ports: PortsToolView()
                    case .whois: WhoisToolView()
                    case .http: HTTPToolView()
                    case .wake: WakeToolView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItem {
                    Button {
                        guard let text = model.resultText() else { return }
                        ConnectionViewModel.copy(text)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy Results", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(model.resultText() == nil)
                    .help("Copy the results as text")
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// The input line every tool starts with: the field, its options, and the button.
private struct ToolInputRow<Options: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let isRunning: Bool
    let runTitle: LocalizedStringKey
    var stopTitle: LocalizedStringKey = "Stop"
    let run: () -> Void
    var stop: (() -> Void)?
    @ViewBuilder var options: Options

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !isRunning { run() } }
                .frame(minWidth: 220)
            options
            if isRunning, let stop {
                Button(stopTitle, action: stop).keyboardShortcut(.cancelAction)
            } else {
                Button(runTitle, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
            if isRunning { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ToolError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

private func ms(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
}

private struct FamilyPicker: View {
    @Binding var preference: AddressPreference

    var body: some View {
        Picker("Address", selection: $preference) {
            Text("Auto").tag(AddressPreference.automatic)
            Text("IPv4").tag(AddressPreference.ipv4)
            Text("IPv6").tag(AddressPreference.ipv6)
        }
        .labelsHidden()
        .fixedSize()
        .help("Which address to use when the name has both")
    }
}

// MARK: - Ping

private struct PingToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "Host name or IP address", text: $model.pingHost, isRunning: model.isPinging,
                         runTitle: "Ping", run: model.startPing, stop: model.stopPing) {
                FamilyPicker(preference: $model.pingPreference)
                Picker("Count", selection: $model.pingCount) {
                    ForEach(ToolsViewModel.pingCounts, id: \.self) { count in
                        if let count { Text("\(count) times").tag(Int?.some(count)) } else { Text("Until stopped").tag(Int?.none) }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            ToolError(message: model.pingError)
            if let target = model.pingTarget {
                let stats = model.pingStats
                HStack(spacing: 24) {
                    StatTile(title: "Address", value: target.description)
                    StatTile(title: "Sent", value: "\(stats.sent)")
                    StatTile(title: "Received", value: "\(stats.received)")
                    StatTile(title: "Loss", value: String(format: "%.0f%%", stats.lossPercent), tint: stats.lossPercent > 0 ? .orange : .primary)
                    StatTile(title: "Min / Avg / Max", value: "\(ms(stats.minimum)) / \(ms(stats.average)) / \(ms(stats.maximum))")
                    StatTile(title: "Std. dev.", value: ms(stats.standardDeviation))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                if model.pingReplies.contains(where: { $0.milliseconds != nil }) {
                    chart.padding(.horizontal, 20).padding(.bottom, 10)
                }
                Divider()
                Table(Array(model.pingReplies.reversed())) {
                    TableColumn("#") { Text(verbatim: "\($0.sequence)").monospacedDigit() }.width(50)
                    TableColumn("From") { Text(verbatim: $0.from ?? "—").monospacedDigit() }.width(min: 120, ideal: 260)
                    TableColumn("Time") { reply in
                        if let value = reply.milliseconds {
                            Text(verbatim: ms(value)).monospacedDigit()
                        } else if let problem = reply.problem {
                            Text(LocalizedStringKey(problem)).foregroundStyle(.orange)
                        } else {
                            Text("Timed out").foregroundStyle(.orange)
                        }
                    }
                    .width(min: 90, ideal: 160)
                    TableColumn("TTL") { Text(verbatim: $0.ttl.map(String.init) ?? "—").monospacedDigit() }.width(50)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.pingReplies.suffix(300)) { reply in
                if let value = reply.milliseconds {
                    LineMark(x: .value("Ping", reply.sequence), y: .value("ms", value))
                        .foregroundStyle(ConnectionChartColor.first)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                } else {
                    RuleMark(x: .value("Ping", reply.sequence))
                        .foregroundStyle(.orange.opacity(0.35))
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text(verbatim: "\(Int(v)) ms") } }
            }
        }
        .frame(height: 120)
    }
}

// MARK: - Traceroute

private struct TraceToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "Host name or IP address", text: $model.traceHost, isRunning: model.isTracing,
                         runTitle: "Trace", run: model.startTrace, stop: model.stopTrace) {
                FamilyPicker(preference: $model.tracePreference)
                Toggle("Keep running (MTR)", isOn: $model.traceContinuous)
                    .help("Send a round every second until stopped, to see which hop loses packets over time")
            }
            ToolError(message: model.traceError)
            if let target = model.traceTarget {
                HStack(spacing: 6) {
                    Text(verbatim: "\(model.traceHost) (\(target))").font(.headline)
                    if model.trace.reachedDestination {
                        Text("· reached in \(model.trace.destinationTTL ?? 0) hops").foregroundStyle(.secondary)
                    } else if !model.isTracing, model.trace.rounds > 0 {
                        Text("· the destination didn't answer").foregroundStyle(.orange)
                    }
                    Text("· \(model.trace.rounds) rounds").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                Divider()
                Table(model.trace.hops) {
                    TableColumn("#") { Text(verbatim: "\($0.ttl)").monospacedDigit() }.width(32)
                    TableColumn("Host") { hop in hostCell(hop) }.width(min: 220, ideal: 330)
                    TableColumn("Loss") { hop in
                        Text(verbatim: String(format: "%.0f%%", hop.lossPercent)).monospacedDigit()
                            .foregroundStyle(hop.lossPercent >= 100 ? Color.secondary : hop.lossPercent > 0 ? .orange : .primary)
                    }
                    .width(50)
                    TableColumn("Last") { Text(verbatim: ms($0.last)).monospacedDigit() }.width(56)
                    TableColumn("Avg") { Text(verbatim: ms($0.average)).monospacedDigit() }.width(56)
                    TableColumn("Best") { Text(verbatim: ms($0.best)).monospacedDigit() }.width(56)
                    TableColumn("Worst") { Text(verbatim: ms($0.worst)).monospacedDigit() }.width(56)
                    TableColumn("Std. dev.") { Text(verbatim: ms($0.standardDeviation)).monospacedDigit() }.width(60)
                }
            } else {
                hint
            }
        }
    }

    /// The name on the first line (the address when there is none), then
    /// the address and the network it belongs to.
    @ViewBuilder
    private func hostCell(_ hop: TraceHop) -> some View {
        if hop.addresses.isEmpty {
            Text(verbatim: "*").foregroundStyle(.secondary)
                .help("No router answered at this hop. Many routers don't reply to traceroute; it doesn't mean packets are lost there.")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(hop.addresses, id: \.self) { address in
                    HStack(spacing: 6) {
                        Text(verbatim: model.hopNames[address] ?? address.description).lineLimit(1)
                        if hop.unreachable { Text("unreachable").foregroundStyle(.orange) }
                    }
                    let details = [model.hopNames[address] == nil ? nil : address.description, model.hopNetworks[address]].compactMap { $0 }
                    if !details.isEmpty {
                        Text(verbatim: details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var hint: some View {
        Text("Each round sends one probe per hop at once, so a trace takes a few seconds. Loss at a middle hop that doesn't carry on to the hops after it is the router limiting its replies, not lost traffic.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DNS

private struct DNSToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "Name or IP address", text: $model.dnsName, isRunning: model.isLookingUp,
                         runTitle: "Look Up", run: model.lookUp) {
                Picker("Type", selection: $model.dnsType) {
                    ForEach(DNSQueryType.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if !model.dnsCompare {
                    Picker("Server", selection: $model.dnsServer) {
                        Text(verbatim: "\(ToolsViewModel.label(.system)) (\(model.systemDNSServer ?? "—"))").tag(DNSServerChoice.system)
                        ForEach([DNSServerChoice.cloudflare, .google, .quad9], id: \.self) { choice in
                            Text(verbatim: "\(ToolsViewModel.label(choice)) (\(choice.fixedAddress ?? ""))").tag(choice)
                        }
                        Text("Other…").tag(DNSServerChoice.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.dnsServer == .custom {
                        TextField("Server IP", text: $model.dnsCustomServer).textFieldStyle(.roundedBorder).frame(width: 130)
                    }
                }
                Toggle("Compare servers", isOn: $model.dnsCompare)
                    .help("Ask this Mac's DNS server, Cloudflare, Google and Quad9 at once")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.dnsRuns) { run in runView(run) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func runView(_ run: ToolsViewModel.DNSRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: "\(run.label) · \(run.server)").font(.headline)
                if let result = run.result {
                    Text(verbatim: result.rcodeName).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background((result.rcode == 0 ? Color.green : .orange).opacity(0.15), in: Capsule())
                        .foregroundStyle(result.rcode == 0 ? Color.green : .orange)
                    Text(verbatim: ms(result.milliseconds)).foregroundStyle(.secondary)
                    if result.authoritative { Text("authoritative").foregroundStyle(.secondary) }
                    if result.usedTCP { Text(verbatim: "TCP").foregroundStyle(.secondary) }
                } else if run.error == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let result = run.result {
                if result.answers.isEmpty {
                    Text(result.rcode == 3 ? "The name doesn't exist." : "No records of this type.").foregroundStyle(.secondary)
                }
                recordGrid(result.answers)
                if !result.authority.isEmpty {
                    Text("Authority").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    recordGrid(result.authority).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func recordGrid(_ records: [DNSAnswerRecord]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(records) { record in
                GridRow {
                    Text(verbatim: record.name).lineLimit(1)
                    Text(verbatim: "\(record.ttl)").monospacedDigit().foregroundStyle(.secondary)
                    Text(verbatim: record.type).fontWeight(.medium)
                    Text(verbatim: record.value).textSelection(.enabled).font(.body.monospaced())
                }
            }
        }
    }
}

// MARK: - Ports

private struct PortsToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "Host name or IP address", text: $model.portHost, isRunning: model.isCheckingPorts,
                         runTitle: "Check", run: model.checkPorts, stop: model.stopPorts) {
                TextField("Ports", text: $model.portsText).textFieldStyle(.roundedBorder).frame(minWidth: 160)
                Menu("Presets") {
                    Button("Common ports") { model.portsText = NetworkMonitor.commonPorts.map(String.init).joined(separator: ", ") }
                    Button("Well-known services") { model.portsText = NetworkMonitor.extendedPorts.map(String.init).joined(separator: ", ") }
                    Button { model.portsText = "1-1024" } label: { Text(verbatim: "1–1024") }
                }
                .fixedSize()
            }
            ToolError(message: model.portError)
            if let target = model.portTarget {
                let open = model.portResults.filter { $0.state == .open }.count
                HStack(spacing: 12) {
                    Text(verbatim: "\(model.portHost) (\(target))").font(.headline)
                    Text("\(open) open · \(model.portResults.count) of \(model.portsTotal) checked").foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Open only", isOn: $model.showsOnlyOpenPorts)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                Divider()
                Table(model.portResults.filter { !model.showsOnlyOpenPorts || $0.state == .open }) {
                    TableColumn("Port") { Text(verbatim: "\($0.port)").monospacedDigit() }.width(70)
                    TableColumn("Service") { Text(verbatim: NetworkDeviceDetailView.serviceName($0.port) ?? "").foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 160)
                    TableColumn("State") { result in
                        switch result.state {
                        case .open: Text("Open").foregroundStyle(.green)
                        case .closed: Text("Closed").foregroundStyle(.secondary)
                        case .filtered: Text("No answer").foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Time") { Text(verbatim: ms($0.milliseconds)).monospacedDigit() }.width(80)
                }
            } else {
                Text("A plain TCP connection to each port, nothing more. Only check hosts you are allowed to test.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}

// MARK: - Whois

private struct WhoisToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "Domain, IP address or AS number", text: $model.whoisQuery, isRunning: model.isQueryingWhois,
                         runTitle: "Look Up", run: model.runWhois) {
                EmptyView()
            }
            ToolError(message: model.whoisError)
            Divider()
            ScrollView {
                Text(verbatim: model.whoisOutput ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}

// MARK: - HTTP

private struct HTTPToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolInputRow(placeholder: "https://example.com", text: $model.httpURL, isRunning: model.isCheckingHTTP,
                         runTitle: "Check", run: model.runHTTPCheck) {
                Toggle("Follow redirects", isOn: $model.followRedirects)
            }
            ToolError(message: model.httpError)
            Divider()
            ScrollView {
                if let result = model.httpResult {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(result)
                        if result.totalMilliseconds != nil { timing(result) }
                        if !result.redirects.isEmpty { redirects(result) }
                        if !result.certificates.isEmpty { certificates(result) }
                        if !result.headers.isEmpty { headers(result) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
    }

    private func summary(_ result: HTTPCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let status = result.status {
                    Text(verbatim: "\(status) \(HTTPToolReason.phrase(status))")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(status < 300 ? Color.green : status < 400 ? .blue : .orange)
                }
                if let error = result.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                row("URL", result.finalURL ?? result.requestedURL)
                row("Server address", result.remoteAddress)
                row("Protocol", [result.httpVersion?.uppercased(), result.tlsVersion].compactMap { $0 }.joined(separator: " · "))
                row("Body", ByteCountFormatter.string(fromByteCount: Int64(result.bodyBytes), countStyle: .file))
            }
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(verbatim: value).textSelection(.enabled)
            }
        }
    }

    private func timing(_ result: HTTPCheckResult) -> some View {
        let total = result.totalMilliseconds ?? 0
        let steps: [(LocalizedStringKey, Double?)] = [
            ("DNS lookup", result.dnsMilliseconds), ("Connect", result.connectMilliseconds), ("TLS handshake", result.tlsMilliseconds),
            ("Waiting for the server", result.firstByteMilliseconds), ("Total", result.totalMilliseconds),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Timing").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    GridRow {
                        Text(step.0).foregroundStyle(.secondary)
                        Text(verbatim: step.1.map { ms($0) } ?? "—").monospacedDigit()
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ConnectionChartColor.first)
                                .frame(width: total > 0 ? geometry.size.width * CGFloat((step.1 ?? 0) / total) : 0)
                        }
                        .frame(width: 260, height: 8)
                    }
                }
            }
            Text("Steps the request didn't need, such as a connection that was already open, show no time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func redirects(_ result: HTTPCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Redirects").font(.headline)
            ForEach(result.redirects) { hop in
                Text(verbatim: "\(hop.status)  \(hop.url) → \(hop.location)").textSelection(.enabled).font(.callout.monospaced())
            }
        }
    }

    private func certificates(_ result: HTTPCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Certificates").font(.headline)
            ForEach(result.certificates) { certificate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: certificate.subject).fontWeight(.medium)
                    if let issuer = certificate.issuer { Text("Issued by \(issuer)").foregroundStyle(.secondary) }
                    if let end = certificate.notAfter {
                        let days = Int(end.timeIntervalSinceNow / 86_400)
                        Text("Valid until \(end, format: .dateTime.day().month().year()) (\(days) days)")
                            .foregroundStyle(days < 0 ? .red : days < 14 ? .orange : .secondary)
                    }
                    if !certificate.dnsNames.isEmpty {
                        Text(verbatim: certificate.dnsNames.prefix(12).joined(separator: ", ") + (certificate.dnsNames.count > 12 ? "…" : ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func headers(_ result: HTTPCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Response headers").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(Array(result.headers.enumerated()), id: \.offset) { _, header in
                    GridRow {
                        Text(verbatim: header.name).foregroundStyle(.secondary)
                        Text(verbatim: header.value).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            .font(.callout.monospaced())
        }
    }
}

enum HTTPToolReason {
    /// The standard reason phrase; Foundation's own wording ("no error" for 200) reads oddly.
    static func phrase(_ status: Int) -> String {
        [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently",
         302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
         400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
         408: "Request Timeout", 410: "Gone", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
         502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"][status]
            ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}

// MARK: - Wake-on-LAN

private struct WakeToolView: View {
    @Bindable private var model = ToolsViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolInputRow(placeholder: "MAC address", text: $model.wakeMAC, isRunning: false, runTitle: "Wake", run: model.wake) {
                Menu("Devices") {
                    if model.wakeableDevices.isEmpty {
                        Text("No device with a known MAC address")
                    }
                    ForEach(model.wakeableDevices) { device in
                        Button { model.wakeMAC = device.mac ?? "" } label: {
                            Text(verbatim: [device.name, device.currentIP, device.mac].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                .fixedSize()
            }
            if let message = model.wakeMessage {
                Label(message, systemImage: model.wakeFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.wakeFailed ? .orange : .secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            Text("Sends a magic packet to the device's network. It wakes only a device whose network card has Wake-on-LAN turned on, on this Mac's network, or on another one when its router passes broadcasts on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(20)
        }
    }
}
