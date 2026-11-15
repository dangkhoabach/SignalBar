import Darwin
import Foundation

// MARK: - Ports

public struct PortCheckResult: Sendable, Equatable, Identifiable {
    public var port: Int
    public var state: TCPPortState
    public var milliseconds: Double?
    public var id: Int { port }
}

public enum PortCheck {
    public static let maxPorts = 1_024

    /// Plain TCP connects to each port, many at once; results arrive as each
    /// port is settled. Nothing beyond the handshake is sent.
    public static func run(_ address: ToolAddress, ports: [Int], timeout: Double = 2, maxInFlight: Int = 32) -> AsyncStream<PortCheckResult> {
        AsyncStream { continuation in
            let cancel = ProbeCancellation()
            continuation.onTermination = { _ in cancel.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.finish() }
                connectAll(address, ports: Array(ports.prefix(maxPorts)), timeout: timeout, maxInFlight: maxInFlight, cancel: cancel) {
                    continuation.yield($0)
                }
            }
        }
    }

    private static func connectAll(
        _ address: ToolAddress, ports: [Int], timeout: Double, maxInFlight: Int, cancel: ProbeCancellation,
        report: (PortCheckResult) -> Void
    ) {
        struct Pending {
            let fd: Int32
            let port: Int
            let started: Date
        }
        var queue = ports.filter { (1...65_535).contains($0) }[...]
        var pending: [Pending] = []
        defer { pending.forEach { close($0.fd) } }

        while (!queue.isEmpty || !pending.isEmpty) && !cancel.isCancelled {
            while pending.count < maxInFlight, let port = queue.popFirst() {
                let fd = socket(address.family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else {
                    report(PortCheckResult(port: port, state: .filtered))
                    continue
                }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let started = Date()
                let outcome = address.withSocketAddress(port: UInt16(port)) { connect(fd, $0, $1) }
                if outcome == 0 || errno == EINPROGRESS {
                    pending.append(Pending(fd: fd, port: port, started: started))
                } else {
                    report(PortCheckResult(port: port, state: errno == ECONNREFUSED ? .closed : .filtered))
                    close(fd)
                }
            }
            var descriptors = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            let now = Date()
            var still: [Pending] = []
            for (item, descriptor) in zip(pending, descriptors) {
                if descriptor.revents != 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(item.fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    let state: TCPPortState = error == 0 ? .open : (error == ECONNREFUSED ? .closed : .filtered)
                    report(PortCheckResult(port: item.port, state: state,
                                           milliseconds: state == .filtered ? nil : now.timeIntervalSince(item.started) * 1000))
                    close(item.fd)
                } else if now.timeIntervalSince(item.started) >= timeout {
                    report(PortCheckResult(port: item.port, state: .filtered))
                    close(item.fd)
                } else {
                    still.append(item)
                }
            }
            pending = still
        }
    }

    /// "22, 80 443, 8000-8010": singles and ranges, de-duplicated and sorted,
    /// at most `maxPorts`; anything else in the text is ignored.
    public static func parse(_ text: String) -> [Int] {
        var ports = Set<Int>()
        for token in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if bounds.count == 1, let port = bounds[0], (1...65_535).contains(port) {
                ports.insert(port)
            } else if bounds.count == 2, let low = bounds[0], let high = bounds[1], 1 <= low, low <= high, high <= 65_535 {
                for port in low...min(high, low + maxPorts) { ports.insert(port) }
            }
        }
        return Array(ports.sorted().prefix(maxPorts))
    }
}

// MARK: - Whois

public enum WhoisError: Error, Equatable, Sendable {
    case invalidQuery
    case failed(String)
}

extension WhoisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuery: "Enter a domain name, an IP address or an AS number."
        case .failed(let reason): reason
        }
    }
}

public enum Whois {
    /// A domain, an address or an AS number; never anything `whois` could read as an option.
    public static func isValidQuery(_ query: String) -> Bool {
        guard !query.isEmpty, query.count <= 255, !query.hasPrefix("-") else { return false }
        return query.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-:_".unicodeScalars.contains($0) }
    }

    /// Runs `/usr/bin/whois`, which starts at IANA and follows its referral
    /// to the registry that holds the record.
    public static func lookup(_ input: String, timeout: Double = 20) async throws -> String {
        let query = ToolTarget.host(from: input)
        guard isValidQuery(query) else { throw WhoisError.invalidQuery }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/whois")
                process.arguments = [query]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: WhoisError.failed(error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: WhoisError.failed("No answer within \(Int(timeout)) seconds."))
                } else if text.isEmpty {
                    continuation.resume(throwing: WhoisError.failed("The whois server sent nothing back."))
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }
}

// MARK: - Wake-on-LAN

public enum WakeOnLAN {
    /// Six 0xFF bytes, then the MAC address sixteen times.
    public static func magicPacket(for mac: MACAddress) -> [UInt8] {
        Array(repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac.bytes, count: 16).joined())
    }

    /// Sends the magic packet three times to each broadcast address, on UDP
    /// port 9. Returns how many sends the kernel accepted.
    @discardableResult
    public static func send(to mac: MACAddress, broadcasts: [IPv4Address], port: UInt16 = 9) -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        let packet = magicPacket(for: mac)
        var accepted = 0
        for _ in 0..<3 {
            for broadcast in Set(broadcasts) {
                let sent = withSocketAddress(socketAddress(broadcast, port: port)) { address, length in
                    packet.withUnsafeBytes { sendto(fd, $0.baseAddress, packet.count, 0, address, length) }
                }
                if sent == packet.count { accepted += 1 }
            }
        }
        return accepted
    }
}
