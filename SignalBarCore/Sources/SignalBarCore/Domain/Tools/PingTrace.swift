import Darwin
import Foundation

/// What came back on an ICMP socket, matched to one of our echoes.
enum EchoEvent: Equatable {
    case reply(sequence: UInt16, ttl: Int?)
    /// A router on the way dropped the echo when its TTL ran out.
    case timeExceeded(sequence: UInt16)
    /// A router or the host said the destination can't be reached.
    case unreachable(sequence: UInt16)
}

/// An unprivileged ICMP or ICMPv6 socket (`SOCK_DGRAM`), which macOS allows
/// without root. It also receives the errors routers send back about our
/// echoes, which is what makes traceroute possible.
final class EchoSocket {
    let family: AddressFamily
    let identifier = UInt16.random(in: 1...UInt16.max)
    private let fd: Int32

    init?(family: AddressFamily) {
        self.family = family
        fd = family == .ipv4 ? socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP) : socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return nil }
        var size: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        // The kernel stamps each packet as it arrives, so a reply that waits
        // in the buffer while a burst of probes goes out is still timed right.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func setHopLimit(_ hops: Int) {
        var value = Int32(hops)
        if family == .ipv4 {
            setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    /// `errno` if the kernel refused it.
    func send(to address: ToolAddress, sequence: UInt16, payloadSize: Int = 56) -> Int32? {
        let packet = Self.echoRequest(family: family, identifier: identifier, sequence: sequence, payloadSize: payloadSize)
        let sent = address.withSocketAddress(port: 0) { pointer, length in
            packet.withUnsafeBytes { sendto(fd, $0.baseAddress, packet.count, 0, pointer, length) }
        }
        return sent == packet.count ? nil : errno
    }

    /// The next event about our echoes within `timeout` seconds, with who
    /// sent it and when it arrived.
    func receive(timeout: Double) -> (event: EchoEvent, from: ToolAddress, at: Date)? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var control = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(max(1, min(left, 0.25) * 1000))) > 0 else { continue }
            var storage = sockaddr_storage()
            var arrived = Date()
            let count = buffer.withUnsafeMutableBytes { data in
                control.withUnsafeMutableBytes { controlBytes in
                    withUnsafeMutablePointer(to: &storage) { address in
                        var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                            var message = msghdr(msg_name: UnsafeMutableRawPointer(address), msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                                                 msg_iov: vectorPointer, msg_iovlen: 1, msg_control: controlBytes.baseAddress,
                                                 msg_controllen: socklen_t(controlBytes.count), msg_flags: 0)
                            let received = recvmsg(fd, &message, 0)
                            if received > 0, let stamp = Self.timestamp(&message) { arrived = stamp }
                            return received
                        }
                    }
                }
            }
            guard count > 0, let from = ToolAddress(storage: storage),
                  let event = Self.parse(buffer[0..<count], family: family, identifier: identifier)
            else { continue }
            return (event, from, arrived)
        }
    }

    private static func timestamp(_ message: inout msghdr) -> Date? {
        guard message.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size), let control = message.msg_control else { return nil }
        let header = control.load(as: cmsghdr.self)
        guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP else { return nil }
        // CMSG_DATA: the header rounded up to the 4-byte alignment Darwin uses.
        let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var time = timeval()
        withUnsafeMutableBytes(of: &time) { $0.copyMemory(from: UnsafeRawBufferPointer(start: control + dataOffset, count: MemoryLayout<timeval>.size)) }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    static func echoRequest(family: AddressFamily, identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
        var packet: [UInt8] = [family == .ipv4 ? 8 : 128, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        // Counting bytes, as ping fills its packets: some networks drop echoes
        // whose payload carries text they don't expect.
        packet += (0..<max(0, payloadSize)).map { UInt8(truncatingIfNeeded: $0) }
        // The kernel fills in the ICMPv6 checksum, which covers the addresses.
        if family == .ipv4 {
            let checksum = HostSweep.internetChecksum(packet)
            packet[2] = UInt8(checksum >> 8)
            packet[3] = UInt8(checksum & 0xFF)
        }
        return packet
    }

    /// macOS hands an IPv4 `SOCK_DGRAM` ICMP socket the IP header too; an
    /// ICMPv6 one gets the ICMP message alone. An error message quotes the
    /// packet it is about after its own 8 bytes: our echo, behind its IP header.
    static func parse(_ bytes: ArraySlice<UInt8>, family: AddressFamily, identifier: UInt16) -> EchoEvent? {
        var icmp = bytes
        var ttl: Int?
        if family == .ipv4, let first = icmp.first, first >> 4 == 4 {
            if icmp.count > 8 { ttl = Int(icmp[icmp.startIndex + 8]) }
            icmp = icmp.dropFirst(Int(first & 0x0F) * 4)
        }
        guard icmp.count >= 8 else { return nil }
        let type = icmp[icmp.startIndex]

        func ids(_ start: ArraySlice<UInt8>.Index, in slice: ArraySlice<UInt8>) -> (UInt16, UInt16) {
            (UInt16(slice[start + 4]) << 8 | UInt16(slice[start + 5]), UInt16(slice[start + 6]) << 8 | UInt16(slice[start + 7]))
        }
        let (replyType, exceededType, unreachableType): (UInt8, UInt8, UInt8) = family == .ipv4 ? (0, 11, 3) : (129, 3, 1)
        if type == replyType {
            let (id, sequence) = ids(icmp.startIndex, in: icmp)
            return id == identifier ? .reply(sequence: sequence, ttl: ttl) : nil
        }
        guard type == exceededType || type == unreachableType else { return nil }
        var quoted = icmp.dropFirst(8)
        if family == .ipv4 {
            guard let first = quoted.first, first >> 4 == 4 else { return nil }
            quoted = quoted.dropFirst(Int(first & 0x0F) * 4)
        } else {
            guard quoted.count >= 40, quoted[quoted.startIndex] >> 4 == 6 else { return nil }
            quoted = quoted.dropFirst(40)
        }
        guard quoted.count >= 8, quoted[quoted.startIndex] == (family == .ipv4 ? 8 : 128) else { return nil }
        let (id, sequence) = ids(quoted.startIndex, in: quoted)
        guard id == identifier else { return nil }
        return type == exceededType ? .timeExceeded(sequence: sequence) : .unreachable(sequence: sequence)
    }
}

// MARK: - Ping

public struct PingReply: Sendable, Equatable, Identifiable {
    public var sequence: Int
    /// `nil` when it timed out or couldn't be sent.
    public var milliseconds: Double?
    public var ttl: Int?
    public var from: String?
    /// Why there was no reply other than a timeout: the kernel's refusal, or a router's "unreachable".
    public var problem: String?
    public var id: Int { sequence }
}

public struct PingOptions: Sendable, Equatable {
    /// `nil` pings until stopped.
    public var count: Int?
    public var interval: Double
    public var payloadSize: Int
    public var timeout: Double

    public init(count: Int? = 10, interval: Double = 1, payloadSize: Int = 56, timeout: Double = 2) {
        self.count = count
        self.interval = interval
        self.payloadSize = payloadSize
        self.timeout = timeout
    }
}

public struct PingStatistics: Sendable, Equatable {
    public var sent: Int
    public var received: Int
    public var minimum: Double?
    public var average: Double?
    public var maximum: Double?
    public var standardDeviation: Double?

    public var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }

    public init(_ replies: [PingReply]) {
        let times = replies.compactMap(\.milliseconds)
        sent = replies.count
        received = times.count
        minimum = times.min()
        maximum = times.max()
        average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        standardDeviation = average.map { mean in (times.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(times.count)).squareRoot() }
    }
}

public enum Ping {
    /// One reply (or timeout) per echo, in order, until `count` or until the stream is dropped.
    public static func run(_ address: ToolAddress, options: PingOptions = PingOptions()) -> AsyncStream<PingReply> {
        AsyncStream { continuation in
            let cancel = ProbeCancellation()
            continuation.onTermination = { _ in cancel.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.finish() }
                guard let socket = EchoSocket(family: address.family) else {
                    continuation.yield(PingReply(sequence: 0, problem: String(cString: strerror(errno))))
                    return
                }
                var pending: [UInt16: Date] = [:]
                var sequence = 0
                var nextSend = Date()
                while !cancel.isCancelled {
                    let now = Date()
                    let wantsMore = options.count.map { sequence < $0 } ?? true
                    if wantsMore, now >= nextSend {
                        let wire = UInt16(truncatingIfNeeded: sequence)
                        if let error = socket.send(to: address, sequence: wire, payloadSize: options.payloadSize) {
                            continuation.yield(PingReply(sequence: sequence, problem: String(cString: strerror(error))))
                        } else {
                            pending[wire] = now
                        }
                        sequence += 1
                        nextSend = now.addingTimeInterval(options.interval)
                    }
                    for (wire, sentAt) in pending where now.timeIntervalSince(sentAt) > options.timeout {
                        pending[wire] = nil
                        continuation.yield(PingReply(sequence: Self.fullSequence(wire, near: sequence)))
                    }
                    if !wantsMore, pending.isEmpty { return }
                    let wait = wantsMore ? max(0.01, nextSend.timeIntervalSinceNow) : 0.1
                    guard let (event, from, arrived) = socket.receive(timeout: min(wait, 0.1)) else { continue }
                    switch event {
                    case .reply(let wire, let ttl):
                        guard let sentAt = pending.removeValue(forKey: wire) else { continue }
                        continuation.yield(PingReply(sequence: Self.fullSequence(wire, near: sequence),
                                                     milliseconds: max(0, arrived.timeIntervalSince(sentAt)) * 1000, ttl: ttl, from: from.description))
                    case .unreachable(let wire), .timeExceeded(let wire):
                        guard pending.removeValue(forKey: wire) != nil else { continue }
                        let problem = event == .unreachable(sequence: wire) ? "Destination unreachable" : "Time to live exceeded"
                        continuation.yield(PingReply(sequence: Self.fullSequence(wire, near: sequence), from: from.description, problem: problem))
                    }
                }
            }
        }
    }

    /// The sequence number on the wire is 16 bits; this is the count it stands for.
    static func fullSequence(_ wire: UInt16, near latest: Int) -> Int {
        let base = latest & ~0xFFFF
        let candidate = base | Int(wire)
        return candidate > latest ? candidate - 0x10000 : candidate
    }
}

// MARK: - Traceroute

/// What one probe at one TTL brought back.
public struct TraceProbe: Sendable, Equatable {
    public var ttl: Int
    public var from: ToolAddress?
    public var milliseconds: Double?
    /// The destination itself answered.
    public var reachedDestination = false
    /// A router answered "can't get there"; nothing past it will answer either.
    public var unreachable = false
}

/// One hop's statistics over every round so far.
public struct TraceHop: Sendable, Equatable, Identifiable {
    public var ttl: Int
    /// Every address that answered at this TTL, most frequent first: load balancers give several.
    public var addresses: [ToolAddress] = []
    public var sent = 0
    public var received = 0
    public var last: Double?
    public var best: Double?
    public var worst: Double?
    private var sum = 0.0
    private var sumOfSquares = 0.0
    private var counts: [ToolAddress: Int] = [:]
    public var unreachable = false

    public var id: Int { ttl }
    public var lossPercent: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }
    public var average: Double? { received == 0 ? nil : sum / Double(received) }
    public var standardDeviation: Double? {
        guard let average else { return nil }
        return max(0, sumOfSquares / Double(received) - average * average).squareRoot()
    }

    init(ttl: Int) { self.ttl = ttl }

    mutating func add(_ probe: TraceProbe) {
        sent += 1
        if probe.unreachable { unreachable = true }
        guard let from = probe.from else { return }
        counts[from, default: 0] += 1
        addresses = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.description < $1.key.description) }.map(\.key)
        guard let ms = probe.milliseconds else { return }
        received += 1
        last = ms
        best = min(best ?? ms, ms)
        worst = max(worst ?? ms, ms)
        sum += ms
        sumOfSquares += ms * ms
    }
}

/// Every round's probes folded into one row per hop, ending at the destination.
public struct TraceSummary: Sendable, Equatable {
    private var allHops: [TraceHop] = []
    public private(set) var rounds = 0
    /// The TTL at which the destination first answered.
    public private(set) var destinationTTL: Int?

    public init() {}

    public var reachedDestination: Bool { destinationTTL != nil }

    public mutating func add(round probes: [TraceProbe]) {
        rounds += 1
        if let reached = probes.filter(\.reachedDestination).map(\.ttl).min() {
            destinationTTL = min(destinationTTL ?? reached, reached)
        }
        for probe in probes where destinationTTL.map({ probe.ttl <= $0 }) ?? true {
            while allHops.count < probe.ttl { allHops.append(TraceHop(ttl: allHops.count + 1)) }
            allHops[probe.ttl - 1].add(probe)
        }
        if let destinationTTL, allHops.count > destinationTTL { allHops.removeLast(allHops.count - destinationTTL) }
    }

    /// The hops to show: up to the destination, or to the first router that
    /// said "unreachable"; when neither answered, up to one silent hop past
    /// the last one that did, rather than a column of stars to the maximum.
    public var hops: [TraceHop] {
        if destinationTTL != nil { return allHops }
        if let unreachable = allHops.firstIndex(where: \.unreachable) { return Array(allHops[...unreachable]) }
        let lastAnswered = allHops.lastIndex { $0.received > 0 } ?? -1
        return Array(allHops.prefix(lastAnswered + 2))
    }
}

public struct TraceOptions: Sendable, Equatable {
    public var maxHops: Int
    /// `nil` repeats until stopped, like mtr.
    public var rounds: Int?
    public var timeout: Double
    public var interval: Double

    public init(maxHops: Int = 30, rounds: Int? = 3, timeout: Double = 1.5, interval: Double = 1) {
        self.maxHops = maxHops
        self.rounds = rounds
        self.timeout = timeout
        self.interval = interval
    }
}

public enum Traceroute {
    /// Each round sends one echo per TTL, all at once, and yields what came back.
    public static func run(_ destination: ToolAddress, options: TraceOptions = TraceOptions()) -> AsyncStream<[TraceProbe]> {
        AsyncStream { continuation in
            let cancel = ProbeCancellation()
            continuation.onTermination = { _ in cancel.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.finish() }
                guard let socket = EchoSocket(family: destination.family) else { return }
                var round = 0
                var limit = min(max(options.maxHops, 1), 63)
                while !cancel.isCancelled, options.rounds.map({ round < $0 }) ?? true {
                    let started = Date()
                    let probes = runRound(socket, destination: destination, round: round, limit: limit, timeout: options.timeout, cancel: cancel)
                    if cancel.isCancelled { return }
                    continuation.yield(probes)
                    if let reached = probes.filter({ $0.reachedDestination || $0.unreachable }).map(\.ttl).min() {
                        limit = min(limit, reached)
                    }
                    round += 1
                    let wait = options.interval - Date().timeIntervalSince(started)
                    if wait > 0, options.rounds.map({ round < $0 }) ?? true { Thread.sleep(forTimeInterval: wait) }
                }
            }
        }
    }

    /// Sequence numbers carry the round in the high bits and the TTL in the low six.
    private static func runRound(
        _ socket: EchoSocket, destination: ToolAddress, round: Int, limit: Int, timeout: Double, cancel: ProbeCancellation
    ) -> [TraceProbe] {
        let tag = UInt16(round & 0x3FF) << 6
        var sentAt: [Int: Date] = [:]
        var probes: [Int: TraceProbe] = [:]
        for ttl in 1...limit {
            socket.setHopLimit(ttl)
            if socket.send(to: destination, sequence: tag | UInt16(ttl)) == nil { sentAt[ttl] = Date() }
            probes[ttl] = TraceProbe(ttl: ttl)
            // Some routers rate-limit their ICMP errors; a short gap spares them a burst.
            usleep(3_000)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancel.isCancelled, Date() < deadline {
            // Done once every hop up to the nearest answer from the destination has answered.
            let end = probes.values.filter { $0.reachedDestination || $0.unreachable }.map(\.ttl).min() ?? limit
            if (1...end).allSatisfy({ probes[$0]?.from != nil }) { break }
            guard let (event, from, arrived) = socket.receive(timeout: deadline.timeIntervalSinceNow) else { break }
            let sequence: UInt16 = switch event {
            case .reply(let sequence, _), .timeExceeded(let sequence), .unreachable(let sequence): sequence
            }
            let ttl = Int(sequence & 0x3F)
            guard sequence & ~0x3F == tag, let sent = sentAt[ttl], probes[ttl]?.from == nil else { continue }
            var probe = TraceProbe(ttl: ttl, from: from, milliseconds: max(0, arrived.timeIntervalSince(sent)) * 1000)
            if case .reply = event { probe.reachedDestination = true }
            if case .unreachable = event { probe.unreachable = true }
            probes[ttl] = probe
        }
        return (1...limit).compactMap { probes[$0] }
    }
}
