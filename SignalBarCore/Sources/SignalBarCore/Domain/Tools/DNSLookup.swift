import Darwin
import Foundation

public enum DNSQueryType: String, Sendable, CaseIterable, Identifiable {
    case a = "A", aaaa = "AAAA", cname = "CNAME", mx = "MX", txt = "TXT", ns = "NS", soa = "SOA", ptr = "PTR", srv = "SRV", caa = "CAA"

    public var id: Self { self }

    public var code: UInt16 {
        switch self {
        case .a: 1
        case .ns: 2
        case .cname: 5
        case .soa: 6
        case .ptr: 12
        case .mx: 15
        case .txt: 16
        case .aaaa: 28
        case .srv: 33
        case .caa: 257
        }
    }

    static func name(of code: UInt16) -> String {
        allCases.first { $0.code == code }?.rawValue ?? "TYPE\(code)"
    }
}

public struct DNSAnswerRecord: Sendable, Equatable, Identifiable {
    public var name: String
    public var type: String
    public var ttl: UInt32
    public var value: String
    public var id: String { "\(name)|\(type)|\(value)" }
}

public struct DNSLookupResult: Sendable, Equatable {
    public var server: String
    /// 0 NOERROR, 2 SERVFAIL, 3 NXDOMAIN, 5 REFUSED…
    public var rcode: Int
    public var authoritative = false
    public var recursionAvailable = false
    public var answers: [DNSAnswerRecord] = []
    public var authority: [DNSAnswerRecord] = []
    public var milliseconds: Double
    public var usedTCP = false

    public var rcodeName: String {
        switch rcode {
        case 0: "NOERROR"
        case 1: "FORMERR"
        case 2: "SERVFAIL"
        case 3: "NXDOMAIN"
        case 4: "NOTIMP"
        case 5: "REFUSED"
        default: "RCODE \(rcode)"
        }
    }
}

public enum DNSLookupError: Error, Equatable, Sendable {
    case badServer
    case noAnswer
}

extension DNSLookupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badServer: "The DNS server must be an IP address."
        case .noAnswer: "The server didn't answer."
        }
    }
}

public enum DNSLookup {
    /// Asks `server` directly, over UDP with EDNS (4096-byte answers), and
    /// again over TCP when the answer came back truncated.
    public static func query(_ name: String, type: DNSQueryType, server: String, timeout: Double = 3) async throws -> DNSLookupResult {
        guard let address = ToolAddress(server) else { throw DNSLookupError.badServer }
        let result: DNSLookupResult? = await runBlocking { cancel in
            let id = UInt16.random(in: 0...UInt16.max)
            let message = DNSMessage.query(name, type: type.code, id: id, edns: true)
            let started = Date()
            guard var reply = exchangeUDP(message, with: address, id: id, timeout: timeout, cancel: cancel) else { return nil }
            var usedTCP = false
            if reply.count > 2, reply[2] & 0x02 != 0, let overTCP = exchangeTCP(message, with: address, timeout: timeout, cancel: cancel) {
                reply = overTCP
                usedTCP = true
            }
            guard var result = parse(reply, server: server, milliseconds: Date().timeIntervalSince(started) * 1000) else { return nil }
            result.usedTCP = usedTCP
            return result
        }
        guard let result else { throw DNSLookupError.noAnswer }
        return result
    }

    /// The name to ask for: an address becomes its reverse (PTR) name.
    public static func queryName(for input: String) -> (name: String, isReverse: Bool) {
        let host = ToolTarget.host(from: input)
        if let address = ToolAddress(host) { return (address.reverseName, true) }
        return (host.hasSuffix(".") ? String(host.dropLast()) : host, false)
    }

    private static func exchangeUDP(_ message: [UInt8], with server: ToolAddress, id: UInt16, timeout: Double, cancel: ProbeCancellation) -> [UInt8]? {
        let fd = socket(server.family == .ipv4 ? AF_INET : AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let sent = server.withSocketAddress(port: 53) { pointer, length in
            message.withUnsafeBytes { sendto(fd, $0.baseAddress, message.count, 0, pointer, length) }
        }
        guard sent == message.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while !cancel.isCancelled, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count >= 12, UInt16(buffer[0]) << 8 | UInt16(buffer[1]) == id { return Array(buffer[0..<count]) }
        }
        return nil
    }

    private static func exchangeTCP(_ message: [UInt8], with server: ToolAddress, timeout: Double, cancel: ProbeCancellation) -> [UInt8]? {
        let fd = socket(server.family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        guard server.withSocketAddress(port: 53, { connect(fd, $0, $1) }) == 0, !cancel.isCancelled else { return nil }
        let framed = [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
        guard framed.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, framed.count, 0) }) == framed.count else { return nil }

        func read(_ count: Int) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: count)
            var have = 0
            while have < count {
                let got = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + have, count - have, 0) }
                guard got > 0 else { return nil }
                have += got
            }
            return data
        }
        guard let length = read(2) else { return nil }
        return read(Int(length[0]) << 8 | Int(length[1]))
    }

    static func parse(_ message: [UInt8], server: String, milliseconds: Double) -> DNSLookupResult? {
        guard message.count >= 12 else { return nil }
        func count(_ at: Int) -> Int { Int(message[at]) << 8 | Int(message[at + 1]) }
        var result = DNSLookupResult(server: server, rcode: Int(message[3] & 0x0F), milliseconds: milliseconds)
        result.authoritative = message[2] & 0x04 != 0
        result.recursionAvailable = message[3] & 0x80 != 0
        var offset = 12
        for _ in 0..<count(4) {
            guard let (_, next) = DNSMessage.readName(message, at: offset), next + 4 <= message.count else { return result }
            offset = next + 4
        }
        func section(_ records: Int) -> [DNSAnswerRecord] {
            var found: [DNSAnswerRecord] = []
            for _ in 0..<records {
                guard let (name, next) = DNSMessage.readName(message, at: offset), next + 10 <= message.count else { break }
                let type = UInt16(message[next]) << 8 | UInt16(message[next + 1])
                let ttl = message[(next + 4)..<(next + 8)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let length = count(next + 8)
                let start = next + 10
                guard start + length <= message.count else { break }
                offset = start + length
                // The EDNS pseudo-record is about the message, not an answer.
                guard type != 41 else { continue }
                found.append(DNSAnswerRecord(name: name.isEmpty ? "." : name, type: DNSQueryType.name(of: type), ttl: ttl,
                                             value: value(of: type, in: message, start: start, length: length)))
            }
            return found
        }
        result.answers = section(count(6))
        result.authority = section(count(8))
        return result
    }

    /// The record's data the way `dig` writes it.
    static func value(of type: UInt16, in message: [UInt8], start: Int, length: Int) -> String {
        let data = Array(message[start..<(start + length)])
        func u16(_ at: Int) -> Int { at + 1 < data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        func u32(_ at: Int) -> UInt32 { at + 3 < data.count ? data[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : 0 }
        func name(at offset: Int) -> String { DNSMessage.readName(message, at: start + offset).map { $0.0.isEmpty ? "." : $0.0 } ?? "?" }
        switch type {
        case 1 where length == 4:
            return data.map(String.init).joined(separator: ".")
        case 28 where length == 16:
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: data) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
            return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        case 2, 5, 12:
            return name(at: 0)
        case 15:
            return "\(u16(0)) \(name(at: 2))"
        case 16:
            var strings: [String] = []
            var at = 0
            while at < data.count {
                let size = Int(data[at])
                let end = min(data.count, at + 1 + size)
                strings.append("\"" + String(decoding: data[(at + 1)..<end], as: UTF8.self) + "\"")
                at = end
            }
            return strings.joined(separator: " ")
        case 6:
            guard let (primary, afterPrimary) = DNSMessage.readName(message, at: start),
                  let (mailbox, afterMailbox) = DNSMessage.readName(message, at: afterPrimary)
            else { return "?" }
            let numbers = afterMailbox - start
            return "\(primary) \(mailbox) " + (0..<5).map { String(u32(numbers + $0 * 4)) }.joined(separator: " ")
        case 33:
            return "\(u16(0)) \(u16(2)) \(u16(4)) \(name(at: 6))"
        case 257 where length >= 2:
            let tagLength = Int(data[1])
            guard 2 + tagLength <= data.count else { return "?" }
            let tag = String(decoding: data[2..<(2 + tagLength)], as: UTF8.self)
            let value = String(decoding: data[(2 + tagLength)...], as: UTF8.self)
            return "\(data[0]) \(tag) \"\(value)\""
        default:
            return "\\# \(length) " + data.map { String(format: "%02x", $0) }.joined()
        }
    }
}

extension DNSMessage {
    /// A recursive query; with `edns`, an OPT record offering 4096-byte UDP answers.
    static func query(_ name: String, type: UInt16, id: UInt16, edns: Bool) -> [UInt8] {
        var message = query(name, type: type, id: id)
        guard edns else { return message }
        message[11] = 1
        message += [0, 0, 41, 0x10, 0x00, 0, 0, 0, 0, 0, 0]
        return message
    }
}
