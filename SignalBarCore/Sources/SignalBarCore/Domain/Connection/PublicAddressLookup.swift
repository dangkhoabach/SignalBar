import Darwin
import Foundation

public enum AddressFamily: String, Sendable, Codable, CaseIterable {
    case ipv4, ipv6
}

/// The address the internet sees this Mac as, and whose network it is.
public struct PublicAddress: Sendable, Equatable {
    public var family: AddressFamily
    public var ip: String
    /// ISO country code, from Cloudflare.
    public var country: String?
    /// The Cloudflare data centre the connection reached, such as `SGN` or `HKG`.
    public var colo: String?
    /// The connection goes through Cloudflare WARP.
    public var warp = false
    public var asn: Int?
    /// The network's registered owner, such as "VNPT Corp".
    public var holder: String?
    public var reverseName: String?
}

/// Finds the public address without an account or key.
///
/// Cloudflare's `/cdn-cgi/trace` page echoes the caller's address with its
/// country and data centre. It is asked at its IPv4 and its IPv6 address
/// separately, so the answer is the address of that one family. When
/// Cloudflare can't be reached over HTTPS, OpenDNS answers the special name
/// `myip.opendns.com` with the address the query came from. RIPEstat, the
/// RIPE NCC's open data API, names the network an address belongs to.
public struct PublicAddressLookup: Sendable {
    static let traceURLs: [AddressFamily: [String]] = [
        .ipv4: ["https://1.1.1.1/cdn-cgi/trace", "https://1.0.0.1/cdn-cgi/trace"],
        .ipv6: ["https://[2606:4700:4700::1111]/cdn-cgi/trace", "https://[2606:4700:4700::1001]/cdn-cgi/trace"],
    ]
    static let openDNSServers: [AddressFamily: String] = [.ipv4: "208.67.222.222", .ipv6: "2620:119:35::35"]

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func address(_ family: AddressFamily) async -> PublicAddress? {
        for text in Self.traceURLs[family] ?? [] {
            guard let url = URL(string: text),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let address = Self.parseTrace(String(decoding: data, as: UTF8.self), family: family)
            else { continue }
            return address
        }
        guard let server = Self.openDNSServers[family] else { return nil }
        let type: DNSRecordType = family == .ipv4 ? .a : .aaaa
        let answer = await runBlocking { cancel in
            DNSClient.query("myip.opendns.com", type: type, server: server, timeout: 2, cancel: cancel)
        }
        guard let ip = answer?.addresses.first, Self.family(of: ip) == family else { return nil }
        return PublicAddress(family: family, ip: ip)
    }

    /// The autonomous system announcing the address and who holds it.
    public func network(of ip: String) async -> (asn: Int, holder: String)? {
        var components = URLComponents(string: "https://stat.ripe.net/data/prefix-overview/data.json")!
        components.queryItems = [URLQueryItem(name: "resource", value: ip), URLQueryItem(name: "sourceapp", value: "signalbar")]
        guard let url = components.url, let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.parseRIPEOverview(data)
    }

    // MARK: - Parsing

    /// `key=value` lines; nil unless the address is there and of the family asked for.
    static func parseTrace(_ text: String, family: AddressFamily) -> PublicAddress? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let ip = fields["ip"], Self.family(of: ip) == family else { return nil }
        var address = PublicAddress(family: family, ip: ip)
        address.country = fields["loc"].flatMap { $0.count == 2 && $0 != "XX" ? $0 : nil }
        address.colo = fields["colo"]
        address.warp = fields["warp"] == "on" || fields["warp"] == "plus"
        return address
    }

    static func parseRIPEOverview(_ data: Data) -> (asn: Int, holder: String)? {
        struct Overview: Decodable {
            struct Body: Decodable {
                struct ASN: Decodable {
                    let asn: Int
                    let holder: String?
                }
                let asns: [ASN]?
            }
            let data: Body
        }
        guard let first = (try? JSONDecoder().decode(Overview.self, from: data))?.data.asns?.first else { return nil }
        return (first.asn, cleanHolder(first.holder ?? ""))
    }

    /// RIPEstat gives "VNPT-AS-VN - VNPT Corp": the AS handle, then the
    /// name. The name alone reads best.
    static func cleanHolder(_ holder: String) -> String {
        let trimmed = holder.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.range(of: " - ") else { return trimmed }
        let name = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? trimmed : name
    }

    static func family(of ip: String) -> AddressFamily? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return .ipv4 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 { return .ipv6 }
        return nil
    }

    /// The PTR name of any address, through the system resolver.
    public static func reverseName(of ip: String) async -> String? {
        await runBlocking { _ in
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(ip, nil, &hints, &result) == 0, let result else { return nil }
            defer { freeaddrinfo(result) }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(result.pointee.ai_addr, result.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
            else { return nil }
            let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return name.hasSuffix(".") ? String(name.dropLast()) : name
        }
    }
}

public enum DNSRecordType: UInt16, Sendable {
    case a = 1
    case aaaa = 28
}

/// One DNS question over UDP to one server, for the checks that need to
/// talk to a particular server rather than whichever the system picks.
enum DNSClient {
    struct Answer: Sendable {
        /// The response code: 0 is an answer, 3 is "no such name".
        var rcode: Int
        var addresses: [String]
        var milliseconds: Double
    }

    static func query(_ name: String, type: DNSRecordType, server: String, timeout: Double, cancel: ProbeCancellation) -> Answer? {
        guard let family = PublicAddressLookup.family(of: server) else { return nil }
        let fd = socket(family == .ipv4 ? AF_INET : AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let id = UInt16.random(in: 0...UInt16.max)
        let message = DNSMessage.query(name, type: type.rawValue, id: id)
        let started = Date()
        let sent: Int = if family == .ipv4 {
            withSocketAddress(socketAddress(IPv4Address(server)!, port: 53)) { address, length in
                message.withUnsafeBytes { sendto(fd, $0.baseAddress, message.count, 0, address, length) }
            }
        } else {
            withIPv6SocketAddress(server, port: 53) { address, length in
                message.withUnsafeBytes { sendto(fd, $0.baseAddress, message.count, 0, address, length) }
            } ?? -1
        }
        guard sent == message.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        while !cancel.isCancelled {
            let left = timeout - Date().timeIntervalSince(started)
            guard left > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(min(left, 0.1) * 1000)) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count >= 12, UInt16(buffer[0]) << 8 | UInt16(buffer[1]) == id else { continue }
            let reply = Array(buffer[0..<count])
            return Answer(rcode: Int(reply[3] & 0x0F), addresses: DNSMessage.addresses(in: reply),
                          milliseconds: Date().timeIntervalSince(started) * 1000)
        }
        return nil
    }

    private static func withIPv6SocketAddress<T>(_ text: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, text, &address.sin6_addr) == 1 else { return nil }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }
}

extension DNSMessage {
    /// A standard recursive query with one question.
    static func query(_ name: String, type: UInt16, id: UInt16) -> [UInt8] {
        var message: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            message.append(UInt8(label.utf8.count))
            message += Array(label.utf8)
        }
        message += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return message
    }

    /// The A and AAAA addresses in the answer section, as text.
    static func addresses(in message: [UInt8]) -> [String] {
        guard message.count >= 12 else { return [] }
        let questions = Int(message[4]) << 8 | Int(message[5])
        let answers = Int(message[6]) << 8 | Int(message[7])
        var offset = 12
        for _ in 0..<questions {
            guard let (_, next) = readName(message, at: offset), next + 4 <= message.count else { return [] }
            offset = next + 4
        }
        var found: [String] = []
        for _ in 0..<answers {
            guard let (_, next) = readName(message, at: offset), next + 10 <= message.count else { break }
            let type = Int(message[next]) << 8 | Int(message[next + 1])
            let length = Int(message[next + 8]) << 8 | Int(message[next + 9])
            let start = next + 10
            guard start + length <= message.count else { break }
            let data = Array(message[start..<start + length])
            if type == 1, length == 4 {
                found.append(data.map(String.init).joined(separator: "."))
            } else if type == 28, length == 16 {
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: data) }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
                found.append(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            offset = start + length
        }
        return found
    }
}
