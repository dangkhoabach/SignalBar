import Foundation

/// Classifies the addresses a monitoring target resolves to.
///
/// The app polls whatever URL a target carries, on a schedule, forever, and
/// targets arrive by JSON import as well as by hand. A target named like an
/// ordinary website but resolving to `169.254.169.254` or a machine on the
/// LAN turns that loop into a probe of the network the app happens to sit in,
/// with the results landing in a report that gets emailed out.
///
/// The rule that follows from that: an address the *user typed* is their own
/// decision and stays allowed — monitoring your own LAN box or a service on
/// localhost is a legitimate thing to want from this app. What gets refused
/// is the mismatch: a public-looking hostname that quietly resolves inward,
/// which is the shape of the attack and never the shape of intent.
public enum InternalAddress {
    /// True for an address that isn't routable on the public internet:
    /// loopback, link-local (including the cloud metadata address), the
    /// RFC1918 private ranges, carrier-grade NAT, and the reserved blocks.
    public static func isInternal(ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return isInternalIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            return isInternalIPv6(v6)
        }
        // Not an address at all — nothing to judge here; the caller only ever
        // passes this the output of a resolver.
        return false
    }

    private static func isInternalIPv4(_ address: UInt32) -> Bool {
        let a = UInt8((address >> 24) & 0xFF)
        let b = UInt8((address >> 16) & 0xFF)
        let c = UInt8((address >> 8) & 0xFF)

        switch a {
        case 0: return true                       // 0.0.0.0/8 "this network"
        case 10: return true                      // 10.0.0.0/8 private
        case 127: return true                     // 127.0.0.0/8 loopback
        case 100: return (b & 0xC0) == 64         // 100.64.0.0/10 CGNAT
        case 169: return b == 254                 // 169.254.0.0/16 link-local + metadata
        case 172: return (b & 0xF0) == 16         // 172.16.0.0/12 private
        case 192:
            if b == 168 { return true }           // 192.168.0.0/16 private
            return b == 0 && c == 0               // 192.0.0.0/24 IETF protocol assignments
        case 198: return b == 18 || b == 19       // 198.18.0.0/15 benchmarking
        case 224...255: return true               // multicast + reserved
        default: return false
        }
    }

    private static func isInternalIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }

        // ::ffff:a.b.c.d — an IPv4 address wearing an IPv6 coat, so judge it
        // as the IPv4 address it actually is rather than letting it through.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let v4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return isInternalIPv4(v4)
        }
        if bytes.allSatisfy({ $0 == 0 }) { return true }                       // ::
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true } // ::1
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true }         // fe80::/10
        if (bytes[0] & 0xFE) == 0xFC { return true }                           // fc00::/7 ULA
        if bytes[0] == 0xFF { return true }                                    // ff00::/8 multicast
        return false
    }

    /// True when the host in the URL is itself an address or a name that
    /// plainly means "this machine / this network".
    ///
    /// These are left alone: typing `192.168.1.50` or `localhost:3000` into
    /// the Add form is an explicit request to monitor something internal, and
    /// an import carrying one is visible as such in the target list. The
    /// check below exists for hostnames that *hide* where they point.
    public static func isNamedDirectly(host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return true }

        let lower = host.lowercased()
        return lower == "localhost"
            || lower.hasSuffix(".localhost")
            || lower.hasSuffix(".local")
    }

    /// Resolves `host` to its addresses.
    ///
    /// Hops off the cooperative pool: `getaddrinfo` blocks, and a slow or
    /// unreachable resolver would otherwise tie up a thread that Swift
    /// concurrency assumes it can keep making progress on.
    public static func resolve(host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blockingResolve(host))
            }
        }
    }

    private static func blockingResolve(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(head) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr, current.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}
