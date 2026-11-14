import Darwin
import Foundation

/// Hostnames for addresses already found, best effort: a name is a hint for
/// the user, never what a device is matched on.
enum NameLookup {
    /// PTR lookups through the system resolver — on most home and office
    /// networks the router's DNS knows the names its DHCP handed out.
    /// Eight at a time: `getnameinfo` blocks for seconds on an address with
    /// no record, and there is no way to cancel it.
    static func reverseDNS(_ addresses: [IPv4Address]) async -> [IPv4Address: String] {
        await withTaskGroup(of: (IPv4Address, String?).self) { group in
            var queue = addresses[...]
            var names: [IPv4Address: String] = [:]
            func addNext() {
                guard let address = queue.popFirst() else { return }
                group.addTask { (address, await runBlocking { _ in reverseName(address) }) }
            }
            for _ in 0..<8 { addNext() }
            while let (address, name) = await group.next() {
                if let name { names[address] = name }
                addNext()
            }
            return names
        }
    }

    private static func reverseName(_ address: IPv4Address) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withSocketAddress(socketAddress(address, port: 0)) { pointer, length in
            getnameinfo(pointer, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        }
        guard status == 0 else { return nil }
        return clean(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Asks the local link who owns each address, the way Bonjour does:
    /// a PTR question for `d.c.b.a.in-addr.arpa` sent to the mDNS group.
    /// Apple devices, printers and most Linux boxes answer for their own
    /// address. Sent from an ordinary port, so the answers come back to it
    /// directly (RFC 6762's "legacy unicast") and port 5353, which macOS's
    /// own responder holds, is never needed. Only reaches the link the Mac
    /// is on: multicast doesn't cross a router.
    static func multicastDNS(_ addresses: [IPv4Address], via interfaceAddress: IPv4Address) async -> [IPv4Address: String] {
        guard !addresses.isEmpty else { return [:] }
        return await runBlocking { cancel in
            queryMulticast(addresses, interfaceAddress: interfaceAddress, wait: 1.5, cancel: cancel)
        }
    }

    private static func queryMulticast(
        _ addresses: [IPv4Address], interfaceAddress: IPv4Address, wait: Double, cancel: ProbeCancellation
    ) -> [IPv4Address: String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var outgoing = in_addr(s_addr: interfaceAddress.value.bigEndian)
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
        var ttl: UInt8 = 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        let group = socketAddress(IPv4Address(0xE000_00FB), port: 5353) // 224.0.0.251
        for start in stride(from: 0, to: addresses.count, by: 25) {
            let query = DNSMessage.ptrQuery(for: Array(addresses[start..<min(start + 25, addresses.count)]))
            _ = withSocketAddress(group) { address, length in
                query.withUnsafeBytes { sendto(fd, $0.baseAddress, query.count, 0, address, length) }
            }
        }

        var names: [IPv4Address: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 9000)
        let deadline = Date().addingTimeInterval(wait)
        while !cancel.isCancelled, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            for (address, name) in DNSMessage.ptrAnswers(in: Array(buffer[0..<count])) {
                if let cleaned = clean(name) { names[address] = cleaned }
            }
        }
        return names
    }

    /// Drops the trailing dot and the `.local` every mDNS name carries; an
    /// answer that is just the address again is no name at all.
    static func clean(_ name: String) -> String? {
        var name = name.hasSuffix(".") ? String(name.dropLast()) : name
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(6)) }
        guard !name.isEmpty, IPv4Address(name) == nil else { return nil }
        return name
    }
}

/// The few bits of the DNS wire format the mDNS lookup needs.
enum DNSMessage {
    static func reverseName(_ address: IPv4Address) -> String {
        let octets = [address.value & 0xFF, address.value >> 8 & 0xFF, address.value >> 16 & 0xFF, address.value >> 24]
        return octets.map(String.init).joined(separator: ".") + ".in-addr.arpa"
    }

    /// One query holding a PTR question per address, each with the
    /// unicast-response bit set.
    static func ptrQuery(for addresses: [IPv4Address]) -> [UInt8] {
        var message: [UInt8] = [0, 0, 0, 0, UInt8(addresses.count >> 8), UInt8(addresses.count & 0xFF), 0, 0, 0, 0, 0, 0]
        for address in addresses {
            for label in reverseName(address).split(separator: ".") {
                message.append(UInt8(label.utf8.count))
                message += Array(label.utf8)
            }
            message += [0, 0, 12, 0x80, 1]
        }
        return message
    }

    /// Every PTR record in the answer and additional sections whose owner
    /// is a reverse name, as (address, target name).
    static func ptrAnswers(in message: [UInt8]) -> [(IPv4Address, String)] {
        guard message.count >= 12 else { return [] }
        let questions = Int(message[4]) << 8 | Int(message[5])
        let records = (Int(message[6]) << 8 | Int(message[7])) + (Int(message[8]) << 8 | Int(message[9]))
            + (Int(message[10]) << 8 | Int(message[11]))
        var offset = 12
        for _ in 0..<questions {
            guard let (_, next) = readName(message, at: offset), next + 4 <= message.count else { return [] }
            offset = next + 4
        }

        var answers: [(IPv4Address, String)] = []
        for _ in 0..<records {
            guard let (owner, next) = readName(message, at: offset), next + 10 <= message.count else { break }
            let type = Int(message[next]) << 8 | Int(message[next + 1])
            let length = Int(message[next + 8]) << 8 | Int(message[next + 9])
            let dataStart = next + 10
            guard dataStart + length <= message.count else { break }
            if type == 12, let address = address(fromReverseName: owner), let (target, _) = readName(message, at: dataStart) {
                answers.append((address, target))
            }
            offset = dataStart + length
        }
        return answers
    }

    static func address(fromReverseName name: String) -> IPv4Address? {
        let lowered = name.lowercased()
        let suffix = ".in-addr.arpa"
        let trimmed = lowered.hasSuffix(suffix + ".") ? String(lowered.dropLast(suffix.count + 1))
            : lowered.hasSuffix(suffix) ? String(lowered.dropLast(suffix.count)) : nil
        guard let trimmed else { return nil }
        let octets = trimmed.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return IPv4Address(octets.reversed().joined(separator: "."))
    }

    /// A possibly compressed name starting at `offset`, and the offset just
    /// past it in the original position. Pointer loops are cut off.
    static func readName(_ message: [UInt8], at offset: Int) -> (String, Int)? {
        var labels: [String] = []
        var position = offset
        var end: Int?
        var jumps = 0
        while position < message.count {
            let length = Int(message[position])
            if length == 0 {
                return (labels.joined(separator: "."), end ?? position + 1)
            }
            if length & 0xC0 == 0xC0 {
                guard position + 1 < message.count, jumps < 16 else { return nil }
                if end == nil { end = position + 2 }
                position = (length & 0x3F) << 8 | Int(message[position + 1])
                jumps += 1
                continue
            }
            guard position + 1 + length <= message.count else { return nil }
            labels.append(String(decoding: message[(position + 1)..<(position + 1 + length)], as: UTF8.self))
            position += 1 + length
        }
        return nil
    }
}
