import Foundation

/// An IPv4 address held as its 32-bit value, so ranges, ordering and
/// containment are plain arithmetic rather than string handling.
public struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    /// Dotted quad only: four decimal parts of 0–255, nothing else.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            value = value << 8 | octet
        }
        self.value = value
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }
}

/// An IPv4 network in CIDR form, always stored canonically: host bits are
/// cleared, so `192.168.1.5/24` and `192.168.1.0/24` are the same network.
public struct IPv4CIDR: Hashable, Sendable, CustomStringConvertible {
    public let network: IPv4Address
    public let prefixLength: Int

    public init(address: IPv4Address, prefixLength: Int) {
        let length = min(max(prefixLength, 0), 32)
        self.prefixLength = length
        self.network = IPv4Address(address.value & Self.mask(length))
    }

    /// `a.b.c.d/n`, with `n` from 0 to 32.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let address = IPv4Address(String(parts[0])),
              (1...2).contains(parts[1].count),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(parts[1]), (0...32).contains(length)
        else { return nil }
        self.init(address: address, prefixLength: length)
    }

    /// From an interface's address and netmask; `nil` for a mask whose ones
    /// aren't contiguous, which no real interface has.
    public init?(address: IPv4Address, netmask: IPv4Address) {
        let ones = (~netmask.value).leadingZeroBitCount
        guard netmask.value == Self.mask(ones) else { return nil }
        self.init(address: address, prefixLength: ones)
    }

    private static func mask(_ length: Int) -> UInt32 {
        length == 0 ? 0 : UInt32.max << (32 - length)
    }

    public var mask: UInt32 { Self.mask(prefixLength) }
    public var broadcast: IPv4Address { IPv4Address(network.value | ~mask) }
    public var addressCount: UInt64 { UInt64(1) << UInt64(32 - prefixLength) }
    public var description: String { "\(network)/\(prefixLength)" }

    public func contains(_ address: IPv4Address) -> Bool {
        address.value & mask == network.value
    }

    public func overlaps(_ other: IPv4CIDR) -> Bool {
        contains(other.network) || other.contains(network)
    }

    /// The addresses a scan probes. The network and broadcast addresses are
    /// left out, except on /31 and /32, which have none to spare.
    public var hosts: [IPv4Address] {
        if prefixLength >= 31 {
            return (network.value...broadcast.value).map(IPv4Address.init)
        }
        return ((network.value + 1)...(broadcast.value - 1)).map(IPv4Address.init)
    }

    /// Entirely inside the ranges that never route on the public internet
    /// (RFC 1918, CGNAT, link-local…): the only networks this app scans.
    public var isInternal: Bool {
        InternalAddress.isInternal(ip: network.description) && InternalAddress.isInternal(ip: broadcast.description)
    }

    /// Internal and holding devices: not loopback, link-local, multicast or
    /// "this network" (0/8), which are internal but nothing to manage.
    public var isManageable: Bool {
        let first = network.value >> 24
        let second = network.value >> 16 & 0xFF
        return isInternal && first != 0 && first != 127 && first < 224 && !(first == 169 && second == 254)
    }
}

/// A 48-bit Ethernet address, printed the one way the app stores it:
/// lowercase, two digits per byte, colon separated.
public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        self.bytes = Array(bytes)
    }

    /// Accepts `aa:bb:cc:dd:ee:ff`, `aa-bb-…`, Cisco's `aabb.ccdd.eeff`,
    /// twelve bare hex digits, and the single-digit bytes `arp` prints
    /// (`a:b:c:d:e:f`).
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts: [Substring]
        if trimmed.contains(":") || trimmed.contains("-") {
            parts = trimmed.split(separator: trimmed.contains(":") ? ":" : "-", omittingEmptySubsequences: false)
            guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) }) else { return nil }
        } else {
            let digits = trimmed.replacingOccurrences(of: ".", with: "")
            guard digits.count == 12 else { return nil }
            parts = stride(from: 0, to: 12, by: 2).map { offset in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                return digits[start..<digits.index(start, offsetBy: 2)]
            }
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.allSatisfy(\.isHexDigit), let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.bytes = bytes
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Set by phones and laptops that hide their hardware address (private
    /// Wi-Fi addresses). Such an address has no manufacturer, and may change.
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    /// Multicast and broadcast: never a device.
    public var isGroup: Bool { bytes[0] & 0x01 != 0 }

    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    /// The 24-bit manufacturer prefix.
    public var oui: UInt32 {
        UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }
}
