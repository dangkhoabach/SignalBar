import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SMCTestView()
                .tabItem { Label("SMC", systemImage: "thermometer") }
            NotificationTestView()
                .tabItem { Label("Notification", systemImage: "bell") }
            SSLTestView()
                .tabItem { Label("SSL", systemImage: "lock") }
            LoginItemTestView()
                .tabItem { Label("Login Item", systemImage: "power") }
        }
        .padding()
        .frame(width: 480, height: 360)
    }
}

// MARK: - SMC

struct SMCTestView: View {
    @State private var log: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Đọc SMC key thật trên máy này. Bấm để thử từng nhóm key.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Đọc nhiệt độ (thử các key ứng viên)") { readTemps() }
                Button("Đọc fan RPM") { readFans() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func readTemps() {
        log.removeAll()
        let reader = SMCReader()
        do {
            try reader.open()
            defer { reader.close() }
            for key in SMCReader.candidateTempKeys {
                do {
                    let value = try reader.readFloatValue(key: key)
                    log.append("\(key): \(value)°C")
                } catch {
                    log.append("\(key): unavailable (\(error))")
                }
            }
        } catch {
            log.append("SMC open failed: \(error)")
        }
    }

    private func readFans() {
        log.removeAll()
        let reader = SMCReader()
        do {
            try reader.open()
            defer { reader.close() }
            let count = reader.fanCount()
            log.append("FNum (fan count) = \(count)")
            if count == 0 {
                // Some Apple Silicon Macs (e.g. fanless Air) legitimately have
                // 0 fans; also try F0Ac directly in case FNum itself is unreadable.
                if let rpm = try? reader.readFloatValue(key: SMCReader.fanActualKey(index: 0)) {
                    log.append("F0Ac (probed anyway): \(rpm) RPM")
                }
            }
            for i in 0..<max(count, 0) {
                let key = SMCReader.fanActualKey(index: i)
                do {
                    let rpm = try reader.readFloatValue(key: key)
                    log.append("\(key): \(rpm) RPM")
                } catch {
                    log.append("\(key): unavailable (\(error))")
                }
            }
        } catch {
            log.append("SMC open failed: \(error)")
        }
    }
}

// MARK: - Notification

struct NotificationTestView: View {
    @StateObject private var manager = NotificationManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authorization status: \(manager.authorizationStatus)")
            Button("Request permission") { manager.requestPermission() }
            Button("Send test notification") { manager.sendTestNotification() }
            Text("Sau khi gửi, ẩn app (Cmd+H) rồi bấm vào notification/nút action:")
                .font(.caption).foregroundStyle(.secondary)
            Text(manager.lastClickResult)
                .font(.system(.caption, design: .monospaced))
        }
        .onAppear { manager.refreshStatus() }
    }
}

// MARK: - SSL

struct SSLTestView: View {
    @State private var host = "dangkhoabach.vn"
    @State private var result = "(chưa chạy)"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("host", text: $host)
            Button("Lấy SSL expiry (native, không shell openssl)") {
                Task {
                    do {
                        let date = try await SSLInspector.fetchExpiryDate(host: host)
                        result = "Expiry: \(date)"
                    } catch {
                        result = "Failed: \(error)"
                    }
                }
            }
            Text(result).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Login Item

struct LoginItemTestView: View {
    @StateObject private var manager = LoginItemManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status: \(manager.status)")
            HStack {
                Button("Enable") { manager.enable() }
                Button("Disable") { manager.disable() }
                Button("Refresh") { manager.refreshStatus() }
            }
            Text("Bật/tắt vài lần rồi kiểm tra System Settings > General > Login Items — không được tạo entry trùng.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { manager.refreshStatus() }
    }
}
