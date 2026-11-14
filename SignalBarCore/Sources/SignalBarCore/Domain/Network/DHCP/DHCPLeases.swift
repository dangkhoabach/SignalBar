import CryptoKit
import Foundation
import os

public struct DHCPLease: Sendable, Equatable {
    public var ip: IPv4Address
    public var mac: MACAddress
    public var hostname: String?
    public var endsAt: Date?
    /// Handed out and not expired. A lease says the address was given to
    /// this MAC; it never says the device is on the network right now.
    public var isActive: Bool
    /// A static mapping configured on the server (a reservation).
    public var isReserved: Bool

    public init(ip: IPv4Address, mac: MACAddress, hostname: String?, endsAt: Date?, isActive: Bool, isReserved: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.endsAt = endsAt
        self.isActive = isActive
        self.isReserved = isReserved
    }
}

/// The lease file formats read over SSH or imported.
public enum DHCPLeaseFormat: String, Sendable, Codable, CaseIterable {
    /// dnsmasq, including OpenWrt and Pi-hole: `/var/lib/misc/dnsmasq.leases`, `/tmp/dhcp.leases`.
    case dnsmasq
    /// ISC dhcpd, including pfSense: `dhcpd.leases`.
    case iscDhcpd = "isc_dhcpd"
    /// Kea's memfile: `kea-leases4.csv`.
    case kea
    /// Any CSV with address, MAC and (optionally) hostname columns.
    case csv
}

public enum DHCPLeaseParser {
    public static func parse(_ text: String, format: DHCPLeaseFormat, now: Date = Date()) -> [DHCPLease] {
        let leases: [DHCPLease] = switch format {
        case .dnsmasq: dnsmasq(text, now: now)
        case .iscDhcpd: iscDhcpd(text, now: now)
        case .kea: kea(text, now: now)
        case .csv: csv(text)
        }
        // A file can list one address several times as it changes hands;
        // the last line wins, as it does for the server.
        var byAddress: [IPv4Address: DHCPLease] = [:]
        for lease in leases { byAddress[lease.ip] = lease }
        return byAddress.values.sorted { $0.ip < $1.ip }
    }

    /// `<expiry epoch> <mac> <ip> <hostname|*> <client id>`; expiry 0 is infinite.
    static func dnsmasq(_ text: String, now: Date) -> [DHCPLease] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 4, let expiry = TimeInterval(fields[0]),
                  let mac = MACAddress(String(fields[1])), let ip = IPv4Address(String(fields[2]))
            else { return nil }
            let ends = expiry == 0 ? nil : Date(timeIntervalSince1970: expiry)
            let hostname = fields[3] == "*" ? nil : String(fields[3])
            return DHCPLease(ip: ip, mac: mac, hostname: hostname, endsAt: ends, isActive: ends.map { $0 > now } ?? true)
        }
    }

    /// `lease <ip> { … }` blocks; times are UTC `weekday yyyy/mm/dd hh:mm:ss`.
    static func iscDhcpd(_ text: String, now: Date) -> [DHCPLease] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"

        var leases: [DHCPLease] = []
        var scanner = text[...]
        while let start = scanner.range(of: "lease ") {
            guard let open = scanner[start.upperBound...].firstIndex(of: "{"),
                  let close = scanner[open...].firstIndex(of: "}")
            else { break }
            let address = scanner[start.upperBound..<open].trimmingCharacters(in: .whitespaces)
            let body = scanner[scanner.index(after: open)..<close]
            scanner = scanner[scanner.index(after: close)...]

            var mac: MACAddress?
            var hostname: String?
            var ends: Date?
            var state = "active"
            for statement in body.split(separator: ";") {
                let words = statement.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                switch words.first {
                case "hardware" where words.count == 3: mac = MACAddress(String(words[2]))
                case "client-hostname" where words.count >= 2:
                    hostname = words.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "ends" where words.count == 4: ends = formatter.date(from: "\(words[2]) \(words[3])")
                case "binding" where words.count == 3 && words[1] == "state": state = String(words[2])
                default: break
                }
            }
            guard let ip = IPv4Address(address), let mac else { continue }
            let active = state == "active" && (ends.map { $0 > now } ?? true)
            leases.append(DHCPLease(ip: ip, mac: mac, hostname: hostname?.isEmpty == false ? hostname : nil, endsAt: ends, isActive: active))
        }
        return leases
    }

    /// Kea memfile CSV with a header naming the columns; `state` 0 is a live lease.
    static func kea(_ text: String, now: Date) -> [DHCPLease] {
        var lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst()
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let addressColumn = column("address"), let macColumn = column("hwaddr") else { return [] }
        let expireColumn = column("expire")
        let hostColumn = column("hostname")
        let stateColumn = column("state")
        return lines.compactMap { fields in
            guard fields.count == header.count, let ip = IPv4Address(fields[addressColumn]),
                  let mac = MACAddress(fields[macColumn])
            else { return nil }
            let ends = expireColumn.flatMap { TimeInterval(fields[$0]) }.map { Date(timeIntervalSince1970: $0) }
            let state = stateColumn.flatMap { Int(fields[$0]) } ?? 0
            let hostname = hostColumn.map { fields[$0].trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return DHCPLease(ip: ip, mac: mac, hostname: hostname?.isEmpty == false ? hostname : nil, endsAt: ends,
                             isActive: state == 0 && (ends.map { $0 > now } ?? true))
        }
    }

    /// Comma, semicolon or tab separated. With a header, the address, MAC and
    /// hostname columns are found by name; without one, they are taken in
    /// that order. Imported rows are treated as reservations.
    static func csv(_ text: String) -> [DHCPLease] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return [] }
        let separator: Character = first.contains("\t") ? "\t" : first.contains(";") ? ";" : ","
        func split(_ line: String) -> [String] {
            line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        let firstFields = split(first).map { $0.lowercased() }
        var ipColumn = 0, macColumn = 1, hostColumn: Int? = 2
        var rows = lines[...]
        if IPv4Address(split(first).first ?? "") == nil {
            ipColumn = firstFields.firstIndex { ["ip", "ip address", "address", "ipaddress"].contains($0) } ?? 0
            macColumn = firstFields.firstIndex { ["mac", "mac address", "mac-address", "hwaddr", "macaddress"].contains($0) } ?? 1
            hostColumn = firstFields.firstIndex { ["hostname", "host", "host-name", "name"].contains($0) }
            rows = rows.dropFirst()
        }
        return rows.compactMap { line in
            let fields = split(line)
            guard fields.count > max(ipColumn, macColumn), let ip = IPv4Address(fields[ipColumn]),
                  let mac = MACAddress(fields[macColumn])
            else { return nil }
            let hostname = hostColumn.flatMap { $0 < fields.count ? fields[$0] : nil }
            return DHCPLease(ip: ip, mac: mac, hostname: hostname?.isEmpty == false ? hostname : nil,
                             endsAt: nil, isActive: true, isReserved: true)
        }
    }

    /// RouterOS REST `/ip/dhcp-server/lease`: a JSON array of string fields.
    static func mikroTik(_ data: Data, now: Date) -> [DHCPLease] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let address = row["address"] as? String, let ip = IPv4Address(address),
                  let macText = row["mac-address"] as? String, let mac = MACAddress(macText)
            else { return nil }
            let hostname = (row["host-name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let expires = (row["expires-after"] as? String).flatMap(routerOSDuration)
            let isStatic = (row["dynamic"] as? String) == "false"
            return DHCPLease(ip: ip, mac: mac, hostname: hostname, endsAt: expires.map { now.addingTimeInterval($0) },
                             isActive: (row["status"] as? String) == "bound", isReserved: isStatic)
        }
    }

    /// `1w2d3h4m5s` → seconds.
    static func routerOSDuration(_ text: String) -> TimeInterval? {
        let units: [Character: Double] = ["w": 604_800, "d": 86_400, "h": 3_600, "m": 60, "s": 1]
        var total = 0.0
        var number = ""
        for character in text {
            if character.isNumber {
                number.append(character)
            } else if let unit = units[character], let value = Double(number) {
                total += value * unit
                number = ""
            } else {
                return nil
            }
        }
        return number.isEmpty && !text.isEmpty ? total : nil
    }
}

public enum DHCPFetchError: Error, Equatable, Sendable {
    case certificateChanged
    case unauthorized
    case httpStatus(Int)
    case unreachable(String)
}

extension DHCPFetchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .certificateChanged:
            "The router's certificate changed since it was first trusted. Check the router, then trust it again in the source's settings."
        case .unauthorized: "The router rejected the user name or password."
        case .httpStatus(let code): "The router answered with HTTP \(code)."
        case .unreachable(let reason): reason
        }
    }
}

/// Reads leases from a MikroTik router's REST API (RouterOS 7).
///
/// Routers serve HTTPS with a certificate they made themselves, which no
/// trust store knows. Rather than turning verification off, the certificate
/// is trusted on first use and pinned: its SHA-256 is stored with the
/// source, and any later change stops the sync, the same rule the Server
/// Manager applies to SSH host keys.
public enum MikroTikLeaseClient {
    /// Returns the leases and the certificate fingerprint seen.
    public static func fetch(
        host: String, port: Int, username: String, password: String, pinnedFingerprint: String?, now: Date = Date()
    ) async throws -> (leases: [DHCPLease], fingerprint: String?) {
        guard let url = URL(string: "https://\(host):\(port)/rest/ip/dhcp-server/lease") else {
            throw DHCPFetchError.unreachable("Invalid address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        let delegate = PinningDelegate(pinned: pinnedFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw DHCPFetchError.unauthorized }
            guard (200...299).contains(status) else { throw DHCPFetchError.httpStatus(status) }
            return (DHCPLeaseParser.mikroTik(data, now: now), delegate.seenFingerprint)
        } catch let error as DHCPFetchError {
            throw error
        } catch {
            if delegate.mismatch { throw DHCPFetchError.certificateChanged }
            throw DHCPFetchError.unreachable(error.localizedDescription)
        }
    }

    final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
        private struct Seen: Sendable {
            var fingerprint: String?
            var mismatch = false
        }

        private let pinned: String?
        private let seen = OSAllocatedUnfairLock(initialState: Seen())

        init(pinned: String?) {
            self.pinned = pinned
        }

        var seenFingerprint: String? { seen.withLock { $0.fingerprint } }
        var mismatch: Bool { seen.withLock { $0.mismatch } }

        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let fingerprint = Self.fingerprint(of: leaf)
            if let pinned, pinned != fingerprint {
                seen.withLock { $0.mismatch = true }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            seen.withLock { $0.fingerprint = fingerprint }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        static func fingerprint(of certificate: SecCertificate) -> String {
            let der = SecCertificateCopyData(certificate) as Data
            return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }
}
