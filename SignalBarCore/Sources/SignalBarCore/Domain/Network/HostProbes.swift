import Darwin
import Foundation
import os

/// Lets a blocking socket loop on a dispatch thread see that the Swift task
/// that started it was cancelled.
final class ProbeCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    func cancel() { flag.withLock { $0 = true } }
    var isCancelled: Bool { flag.withLock { $0 } }
}

/// Runs socket work that blocks (`poll`, `getnameinfo`) on a dispatch thread
/// rather than the cooperative pool, which Swift concurrency assumes always
/// makes progress, and forwards task cancellation into it.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable (ProbeCancellation) -> T) async -> T {
    let token = ProbeCancellation()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work(token))
            }
        }
    } onCancel: {
        token.cancel()
    }
}

func socketAddress(_ ip: IPv4Address, port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = ip.value.bigEndian
    return address
}

func withSocketAddress<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var copy = address
    return withUnsafePointer(to: &copy) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

private func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// What one sweep of a list of addresses heard back.
struct SweepResult: Sendable {
    /// Addresses that answered an ICMP echo, with the round trip in ms.
    var echoReplies: [IPv4Address: Double] = [:]
    /// On-link addresses that answered ARP: still accepted by the kernel
    /// after every other address was refused. Empty for a routed sweep.
    var answeredARP: Set<IPv4Address> = []
    /// `errno` of every address the kernel refused on the first pass.
    var firstPassErrors: [IPv4Address: Int32] = [:]
}

/// Spreads sends evenly over time. Each send waits for its own slot rather
/// than sleeping a fixed gap after the last one: macOS coalesces short timers
/// on background threads, and fixed sleeps that each overrun added up to a
/// sweep several times slower than its rate.
struct Pacer {
    private let started = monotonicSeconds()
    private let interval: Double
    private var count = 0

    init(perSecond rate: Double) {
        interval = 1 / rate
    }

    mutating func wait() {
        let due = started + Double(count) * interval
        count += 1
        let ahead = due - monotonicSeconds()
        if ahead > 0.002 { usleep(useconds_t(ahead * 1_000_000)) }
    }
}

/// Finds which addresses are in use, by ICMP echo and, on the Mac's own
/// link, by ARP — without reading the ARP cache, which current macOS hides
/// from apps.
///
/// Sending anything to an on-link address makes the kernel ARP for it. An
/// address that never answers is marked down after a few unanswered
/// requests (`net.link.ether.inet.maxtries`), and from then on a send to it
/// is refused at once with "host is down". So a datagram is sent to every
/// address several times, about a second apart; whatever the kernel still
/// accepts on the last pass answered ARP. Every device answers ARP, even
/// one whose firewall drops pings and closes every port. The datagrams are
/// empty and go to port 9, the discard service.
///
/// The echo uses a `SOCK_DGRAM` ICMP socket, which macOS allows without root.
/// Sends are paced at 200 a second: each one on the link costs an ARP
/// broadcast, and switches that police ARP shut ports that send too many.
enum HostSweep {
    static let sendsPerSecond = 200.0
    /// Passes after the first before the kernel has given up on every silent
    /// address; measured on macOS 26 with the default `maxtries` of 5.
    static let arpPasses = 6
    static let passSpacing = 1.1
    static let replyWait = 1.5

    static func run(_ hosts: [IPv4Address], onLink: Bool, cancel: ProbeCancellation) -> SweepResult {
        var result = SweepResult()
        let icmp = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        let udp = onLink ? socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP) : -1
        defer {
            if icmp >= 0 { close(icmp) }
            if udp >= 0 { close(udp) }
        }
        guard icmp >= 0 else { return result }
        _ = fcntl(icmp, F_SETFL, fcntl(icmp, F_GETFL) | O_NONBLOCK)
        var bufferSize: Int32 = 256 * 1024
        setsockopt(icmp, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        let identifier = UInt16.random(in: 1...UInt16.max)
        var sentAt: [IPv4Address: Double] = [:]
        var pacer = Pacer(perSecond: sendsPerSecond)

        // First pass: the echo, and on the link the first datagram.
        var passStarted = monotonicSeconds()
        for (index, host) in hosts.enumerated() {
            if cancel.isCancelled { return result }
            pacer.wait()
            if udp >= 0, let error = sendDatagram(udp, to: host) {
                result.firstPassErrors[host] = error
            }
            let packet = echoRequest(identifier: identifier, sequence: UInt16(truncatingIfNeeded: index))
            let sent = withSocketAddress(socketAddress(host, port: 0)) { address, length in
                packet.withUnsafeBytes { sendto(icmp, $0.baseAddress, packet.count, 0, address, length) }
            }
            if sent < 0 {
                if udp < 0 { result.firstPassErrors[host] = errno }
            } else {
                sentAt[host] = monotonicSeconds()
            }
            drainReplies(icmp, identifier: identifier, sentAt: sentAt, into: &result)
        }

        if udp >= 0 {
            var accepted = Set(hosts)
            for _ in 0..<arpPasses {
                // The kernel retries ARP for an address at most once a second,
                // so passes over a short list wait; a long list is its own gap.
                while monotonicSeconds() - passStarted < passSpacing, !cancel.isCancelled {
                    waitForReplies(icmp, seconds: 0.05, identifier: identifier, sentAt: sentAt, into: &result)
                }
                passStarted = monotonicSeconds()
                pacer = Pacer(perSecond: sendsPerSecond)
                for host in hosts where accepted.contains(host) {
                    if cancel.isCancelled { return result }
                    pacer.wait()
                    if sendDatagram(udp, to: host) != nil { accepted.remove(host) }
                }
                drainReplies(icmp, identifier: identifier, sentAt: sentAt, into: &result)
            }
            result.answeredARP = accepted
        }

        let deadline = monotonicSeconds() + replyWait
        while !cancel.isCancelled, monotonicSeconds() < deadline {
            waitForReplies(icmp, seconds: 0.1, identifier: identifier, sentAt: sentAt, into: &result)
        }
        return result
    }

    /// `errno` if the kernel refused it.
    private static func sendDatagram(_ fd: Int32, to host: IPv4Address) -> Int32? {
        let sent = withSocketAddress(socketAddress(host, port: 9)) { sendto(fd, nil, 0, 0, $0, $1) }
        return sent < 0 ? errno : nil
    }

    private static func waitForReplies(
        _ fd: Int32, seconds: Double, identifier: UInt16, sentAt: [IPv4Address: Double], into result: inout SweepResult
    ) {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, Int32(seconds * 1000)) > 0 {
            drainReplies(fd, identifier: identifier, sentAt: sentAt, into: &result)
        }
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += Array("SignalBr".utf8)
        let checksum = internetChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Whether this is an echo reply carrying our identifier. macOS hands a `SOCK_DGRAM`
    /// ICMP socket the IP header too, so it is skipped when present.
    static func isEchoReply(_ bytes: ArraySlice<UInt8>, identifier: UInt16) -> Bool {
        var icmp = bytes
        if let first = icmp.first, first >> 4 == 4 {
            icmp = icmp.dropFirst(Int(first & 0x0F) * 4)
        }
        guard icmp.count >= 8 else { return false }
        let start = icmp.startIndex
        let replyIdentifier = UInt16(icmp[start + 4]) << 8 | UInt16(icmp[start + 5])
        return icmp[start] == 0 && replyIdentifier == identifier
    }

    private static func drainReplies(_ fd: Int32, identifier: UInt16, sentAt: [IPv4Address: Double], into result: inout SweepResult) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0 else { return }
            guard isEchoReply(buffer[0..<count], identifier: identifier) else { continue }
            let source = IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr))
            if let sent = sentAt[source], result.echoReplies[source] == nil {
                result.echoReplies[source] = (monotonicSeconds() - sent) * 1000
            }
        }
    }
}

public enum TCPPortState: String, Sendable, Codable, CaseIterable {
    /// The handshake completed.
    case open
    /// The host answered with a reset: it's there, the port isn't.
    case closed
    /// No answer, or the network refused to deliver: a firewall dropping the
    /// packet looks exactly like no host at all.
    case filtered
}

struct TCPProbeResult: Sendable, Equatable {
    let ip: IPv4Address
    let port: UInt16
    let state: TCPPortState
    let latencyMs: Double?
}

/// Plain TCP connects (a full handshake, closed straight away), many in
/// flight at once with non-blocking sockets and one `poll`. No raw packets:
/// nothing here needs root or looks like a stealth scan.
enum TCPConnectProbe {
    static func run(
        _ targets: [(IPv4Address, UInt16)], timeout: TimeInterval, maxInFlight: Int, cancel: ProbeCancellation
    ) -> [TCPProbeResult] {
        struct Pending {
            let fd: Int32
            let ip: IPv4Address
            let port: UInt16
            let started: Double
        }
        var results: [TCPProbeResult] = []
        var queue = targets[...]
        var pending: [Pending] = []
        defer { pending.forEach { close($0.fd) } }

        while (!queue.isEmpty || !pending.isEmpty) && !cancel.isCancelled {
            while pending.count < maxInFlight, let (ip, port) = queue.popFirst() {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else {
                    results.append(TCPProbeResult(ip: ip, port: port, state: .filtered, latencyMs: nil))
                    continue
                }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let started = monotonicSeconds()
                let outcome = withSocketAddress(socketAddress(ip, port: port)) { connect(fd, $0, $1) }
                if outcome == 0 || errno == EINPROGRESS {
                    pending.append(Pending(fd: fd, ip: ip, port: port, started: started))
                } else {
                    results.append(TCPProbeResult(ip: ip, port: port, state: errno == ECONNREFUSED ? .closed : .filtered, latencyMs: nil))
                    close(fd)
                }
            }

            var descriptors = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            let now = monotonicSeconds()
            var stillPending: [Pending] = []
            for (item, descriptor) in zip(pending, descriptors) {
                if descriptor.revents != 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(item.fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    let state: TCPPortState = error == 0 ? .open : (error == ECONNREFUSED ? .closed : .filtered)
                    let latency = state == .filtered ? nil : (now - item.started) * 1000
                    results.append(TCPProbeResult(ip: item.ip, port: item.port, state: state, latencyMs: latency))
                    close(item.fd)
                } else if now - item.started >= timeout {
                    results.append(TCPProbeResult(ip: item.ip, port: item.port, state: .filtered, latencyMs: nil))
                    close(item.fd)
                } else {
                    stillPending.append(item)
                }
            }
            pending = stillPending
        }
        return results
    }
}
