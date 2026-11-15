import Darwin
import Foundation

/// An IPv4 or IPv6 address for the tools, which take either.
public struct ToolAddress: Hashable, Sendable, CustomStringConvertible {
    public let family: AddressFamily
    /// 4 or 16 bytes, network order.
    let bytes: [UInt8]

    public init?(_ text: String) {
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            family = .ipv4
            bytes = withUnsafeBytes(of: v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        family = .ipv6
        bytes = withUnsafeBytes(of: v6) { Array($0) }
    }

    init(_ v4: IPv4Address) {
        family = .ipv4
        bytes = [UInt8(v4.value >> 24), UInt8(v4.value >> 16 & 0xFF), UInt8(v4.value >> 8 & 0xFF), UInt8(v4.value & 0xFF)]
    }

    /// From a socket address the kernel filled in.
    init?(storage: sockaddr_storage) {
        var copy = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            let address = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr } }
            family = .ipv4
            bytes = withUnsafeBytes(of: address) { Array($0) }
        case AF_INET6:
            let address = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr } }
            family = .ipv6
            bytes = withUnsafeBytes(of: address) { Array($0) }
        default:
            return nil
        }
    }

    public var description: String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { raw in
            _ = inet_ntop(family == .ipv4 ? AF_INET : AF_INET6, raw.baseAddress, &text, socklen_t(text.count))
        }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Private, link-local, CGNAT and the like: no network registry knows them.
    public var isInternal: Bool { InternalAddress.isInternal(ip: description) }

    func withSocketAddress<T>(port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        if family == .ipv4 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    /// The name a PTR lookup asks for.
    public var reverseName: String {
        if family == .ipv4 {
            return bytes.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
        }
        let nibbles = bytes.flatMap { [$0 >> 4, $0 & 0x0F] }.reversed().map { String($0, radix: 16) }
        return nibbles.joined(separator: ".") + ".ip6.arpa"
    }
}

public enum AddressPreference: String, Sendable, CaseIterable {
    case automatic, ipv4, ipv6
}

public enum ToolTargetError: Error, Equatable, Sendable {
    case empty
    case notResolved(String)
}

extension ToolTargetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a host name or an address."
        case .notResolved(let host): "\(host) could not be resolved."
        }
    }
}

/// Turns what the user typed (a name, an address, or a URL) into the address to use.
public enum ToolTarget {
    /// The host part of `text`: a URL's host, or the text with spaces trimmed.
    public static func host(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let host = URLComponents(string: trimmed)?.host { return host }
        if let slash = trimmed.firstIndex(of: "/"), !trimmed.contains(":") { return String(trimmed[..<slash]) }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    public static func resolve(_ text: String, preference: AddressPreference = .automatic) async throws -> ToolAddress {
        let host = host(from: text)
        guard !host.isEmpty else { throw ToolTargetError.empty }
        if let address = ToolAddress(host) { return address }
        let found = await InternalAddress.resolve(host: host).compactMap(ToolAddress.init)
        let pick: ToolAddress? = switch preference {
        case .automatic: found.first { $0.family == .ipv4 } ?? found.first
        case .ipv4: found.first { $0.family == .ipv4 }
        case .ipv6: found.first { $0.family == .ipv6 }
        }
        guard let pick else { throw ToolTargetError.notResolved(host) }
        return pick
    }
}
