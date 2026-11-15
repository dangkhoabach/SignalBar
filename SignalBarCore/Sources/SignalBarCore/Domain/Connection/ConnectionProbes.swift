import Darwin
import Foundation

/// Whether there is another NAT between the router and the internet, read
/// from the first hop past the router.
public enum NATLayout: String, Sendable, Equatable {
    /// The hop past the router is a public address: the router's WAN side is on the internet.
    case single
    /// The hop past the router is a private address: another router (often
    /// the provider's modem) translates again. Port forwarding on this router alone won't work.
    case double
    /// The hop past the router is in 100.64.0.0/10, the shared space
    /// providers use for carrier-grade NAT: no port can be opened from outside.
    case carrierGrade
    /// The hops didn't answer, or traffic goes through a VPN.
    case unknown

    /// `hops[0]` is the router itself.
    public static func classify(hops: [IPv4Address?]) -> NATLayout {
        guard hops.count > 1, let next = hops[1] else { return .unknown }
        if IPv4CIDR("100.64.0.0/10")!.contains(next) { return .carrierGrade }
        return InternalAddress.isInternal(ip: next.description) ? .double : .single
    }
}

/// A router on the way out, and how long it took to answer.
public struct RouteHop: Sendable, Equatable {
    public var address: IPv4Address
    public var milliseconds: Double
}

/// ICMP echoes and TTL-limited echoes on an unprivileged `SOCK_DGRAM`
/// socket, which macOS allows without root and which also receives the
/// "time exceeded" a router sends back when the TTL runs out.
enum EchoProbe {
    /// One echo to each target at once; round trips in ms for those that answered within `timeout`.
    static func round(_ targets: [IPv4Address], timeout: Double, cancel: ProbeCancellation) -> [IPv4Address: Double] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0, !targets.isEmpty else { return [:] }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        var sentAt: [IPv4Address: Date] = [:]
        for (index, target) in Set(targets).enumerated() {
            let packet = HostSweep.echoRequest(identifier: identifier, sequence: UInt16(index))
            let sent = withSocketAddress(socketAddress(target, port: 0)) { address, length in
                packet.withUnsafeBytes { sendto(fd, $0.baseAddress, packet.count, 0, address, length) }
            }
            if sent == packet.count { sentAt[target] = Date() }
        }

        var replies: [IPv4Address: Double] = [:]
        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = Date().addingTimeInterval(timeout)
        while !cancel.isCancelled, replies.count < sentAt.count, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0, HostSweep.isEchoReply(buffer[0..<count], identifier: identifier) else { continue }
            let source = IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr))
            if let sent = sentAt[source], replies[source] == nil {
                replies[source] = Date().timeIntervalSince(sent) * 1000
            }
        }
        return replies
    }

    /// The routers on the first `maxHops` hops towards `destination`, like
    /// the start of a traceroute: `nil` where a hop didn't answer in time.
    static func firstHops(
        towards destination: IPv4Address, maxHops: Int, timeout: Double, cancel: ProbeCancellation
    ) -> [RouteHop?] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        var hops: [RouteHop?] = []
        var buffer = [UInt8](repeating: 0, count: 1500)
        for ttl in 1...maxHops {
            if cancel.isCancelled { break }
            var value = Int32(ttl)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
            let packet = HostSweep.echoRequest(identifier: identifier, sequence: UInt16(ttl))
            let started = Date()
            _ = withSocketAddress(socketAddress(destination, port: 0)) { address, length in
                packet.withUnsafeBytes { sendto(fd, $0.baseAddress, packet.count, 0, address, length) }
            }
            var hop: RouteHop?
            while hop == nil, !cancel.isCancelled, Date().timeIntervalSince(started) < timeout {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 50) > 0 else { continue }
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
                }
                guard count > 0 else { continue }
                let reply = buffer[0..<count]
                if isTimeExceeded(reply, identifier: identifier, sequence: UInt16(ttl))
                    || HostSweep.isEchoReply(reply, identifier: identifier) {
                    hop = RouteHop(address: IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)),
                                   milliseconds: Date().timeIntervalSince(started) * 1000)
                }
            }
            hops.append(hop)
            // Reached the destination itself: there are no further hops.
            if hop?.address == destination { break }
        }
        return hops
    }

    /// A "time exceeded in transit" whose quoted packet is our echo with this sequence number.
    static func isTimeExceeded(_ bytes: ArraySlice<UInt8>, identifier: UInt16, sequence: UInt16) -> Bool {
        var icmp = bytes
        if let first = icmp.first, first >> 4 == 4 { icmp = icmp.dropFirst(Int(first & 0x0F) * 4) }
        guard icmp.count >= 8 + 20 + 8, icmp[icmp.startIndex] == 11 else { return false }
        let quoted = icmp.dropFirst(8)
        guard let first = quoted.first, first >> 4 == 4 else { return false }
        let inner = quoted.dropFirst(Int(first & 0x0F) * 4)
        guard inner.count >= 8, inner[inner.startIndex] == 8 else { return false }
        let start = inner.startIndex
        return UInt16(inner[start + 4]) << 8 | UInt16(inner[start + 5]) == identifier
            && UInt16(inner[start + 6]) << 8 | UInt16(inner[start + 7]) == sequence
    }
}

/// How quickly a DNS server answered a lookup sent straight to it.
public struct DNSServerTiming: Sendable, Equatable {
    public var server: String
    /// `nil` when it didn't answer in time, or can't be asked directly (a link-local address).
    public var milliseconds: Double?
}

enum DNSChecks {
    /// A name every resolver can answer, so the time measured is the server's, not an authority's.
    static let probeName = "www.apple.com"

    static func timings(_ servers: [String]) async -> [DNSServerTiming] {
        await withTaskGroup(of: (Int, DNSServerTiming).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    guard !server.lowercased().hasPrefix("fe80"), !server.contains("%") else {
                        return (index, DNSServerTiming(server: server, milliseconds: nil))
                    }
                    let answer = await runBlocking { cancel in
                        DNSClient.query(probeName, type: .a, server: server, timeout: 2, cancel: cancel)
                    }
                    return (index, DNSServerTiming(server: server, milliseconds: answer.map(\.milliseconds)))
                }
            }
            var results: [(Int, DNSServerTiming)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The address of whichever resolver finally asks the internet on this
    /// Mac's behalf. Akamai's `whoami.akamai.net` answers with the address of
    /// the server that asked it, so looking it up through the system resolver
    /// shows where DNS really leaves: the provider's resolver, a public one,
    /// or something in between that rewrote the route.
    static func resolverEgress() async -> String? {
        await runBlocking { _ in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo("whoami.akamai.net", nil, &hints, &result) == 0, let result else { return nil }
            defer { freeaddrinfo(result) }
            let address = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return IPv4Address(UInt32(bigEndian: address)).description
        }
    }
}

/// Pings for the live latency chart.
public enum LatencyProbe {
    /// One echo to each target at once; round trips in ms for those that answered.
    public static func ping(_ targets: [IPv4Address], timeout: Double = 1.5) async -> [IPv4Address: Double] {
        await runBlocking { cancel in EchoProbe.round(targets, timeout: timeout, cancel: cancel) }
    }
}
