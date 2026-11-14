import Foundation

/// An SNMP object identifier, e.g. `1.3.6.1.2.1.1.5.0`.
public struct OID: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let components: [UInt32]

    public init(_ components: [UInt32]) {
        self.components = components
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".")
        let components = parts.compactMap { UInt32($0) }
        guard components.count >= 2, components.count == parts.count else { return nil }
        self.components = components
    }

    public init(stringLiteral value: String) {
        self.components = value.split(separator: ".").map { UInt32($0)! }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public func appending(_ more: UInt32...) -> OID { OID(components + more) }

    public func isPrefix(of other: OID) -> Bool {
        other.components.count > components.count && Array(other.components.prefix(components.count)) == components
    }

    /// What follows `prefix` in this OID — the row index of a table column.
    public func suffix(after prefix: OID) -> [UInt32] {
        Array(components.dropFirst(prefix.components.count))
    }

    public static func < (lhs: OID, rhs: OID) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public enum SNMPValue: Sendable, Equatable {
    case integer(Int64)
    case octets([UInt8])
    case null
    case oid(OID)
    case ipAddress(IPv4Address)
    case counter32(UInt32)
    case gauge32(UInt32)
    case timeTicks(UInt32)
    case opaque([UInt8])
    case counter64(UInt64)
    case noSuchObject
    case noSuchInstance
    case endOfMibView

    /// The value as a number, whatever numeric type the agent chose.
    public var unsigned: UInt64? {
        switch self {
        case .integer(let value): value >= 0 ? UInt64(value) : nil
        case .counter32(let value), .gauge32(let value), .timeTicks(let value): UInt64(value)
        case .counter64(let value): value
        default: nil
        }
    }

    public var text: String? {
        guard case .octets(let bytes) = self else { return nil }
        let string = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return string.isEmpty ? nil : string
    }

    /// True for the three "there is nothing here" answers SNMPv2 uses in
    /// place of an error.
    public var isException: Bool {
        self == .noSuchObject || self == .noSuchInstance || self == .endOfMibView
    }
}

enum BERError: Error, Equatable {
    case truncated
    case unexpectedTag(UInt8)
    case invalid(String)
}

/// The Basic Encoding Rules subset SNMP uses: definite lengths, primitive
/// integers, strings, OIDs, and constructed sequences.
enum BER {
    enum Tag {
        static let integer: UInt8 = 0x02
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let oid: UInt8 = 0x06
        static let sequence: UInt8 = 0x30
        static let ipAddress: UInt8 = 0x40
        static let counter32: UInt8 = 0x41
        static let gauge32: UInt8 = 0x42
        static let timeTicks: UInt8 = 0x43
        static let opaque: UInt8 = 0x44
        static let counter64: UInt8 = 0x46
        static let noSuchObject: UInt8 = 0x80
        static let noSuchInstance: UInt8 = 0x81
        static let endOfMibView: UInt8 = 0x82
    }

    // MARK: Encoding

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func integer(_ value: Int64, tag: UInt8 = Tag.integer) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        // Shortest two's complement form: drop a leading byte while the
        // next one already carries the same sign.
        while bytes.count > 1,
              (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return tlv(tag, bytes)
    }

    static func unsigned(_ value: UInt64, tag: UInt8) -> [UInt8] {
        var bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
        while bytes.count > 1, bytes[0] == 0, bytes[1] & 0x80 == 0 { bytes.removeFirst() }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(tag, bytes)
    }

    static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(Tag.octetString, bytes) }
    static func null() -> [UInt8] { [Tag.null, 0] }
    static func sequence(_ items: [[UInt8]], tag: UInt8 = Tag.sequence) -> [UInt8] { tlv(tag, items.flatMap { $0 }) }

    /// The first two components share one subidentifier (`40 × a + b`);
    /// every subidentifier is base-128 with the high bit marking "more".
    static func oid(_ oid: OID) -> [UInt8] {
        let parts = oid.components
        var content: [UInt8] = []
        for subidentifier in [parts[0] * 40 + parts[1]] + parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(subidentifier & 0x7F)]
            var remaining = subidentifier >> 7
            while remaining > 0 {
                chunk.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
                remaining >>= 7
            }
            content += chunk
        }
        return tlv(Tag.oid, content)
    }

    static func value(_ value: SNMPValue) -> [UInt8] {
        switch value {
        case .integer(let number): integer(number)
        case .octets(let bytes): octets(bytes)
        case .null: null()
        case .oid(let identifier): oid(identifier)
        case .ipAddress(let address): tlv(Tag.ipAddress, withUnsafeBytes(of: address.value.bigEndian, Array.init))
        case .counter32(let number): unsigned(UInt64(number), tag: Tag.counter32)
        case .gauge32(let number): unsigned(UInt64(number), tag: Tag.gauge32)
        case .timeTicks(let number): unsigned(UInt64(number), tag: Tag.timeTicks)
        case .opaque(let bytes): tlv(Tag.opaque, bytes)
        case .counter64(let number): unsigned(number, tag: Tag.counter64)
        case .noSuchObject: [Tag.noSuchObject, 0]
        case .noSuchInstance: [Tag.noSuchInstance, 0]
        case .endOfMibView: [Tag.endOfMibView, 0]
        }
    }

    // MARK: Decoding

    /// Reads TLVs one after another out of a byte slice. The slices it hands
    /// back keep their indices into the original message, which is how the
    /// authentication parameters are found again for verification.
    struct Reader {
        private(set) var bytes: ArraySlice<UInt8>

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { bytes.isEmpty }

        mutating func read() throws -> (tag: UInt8, content: ArraySlice<UInt8>) {
            guard let tag = bytes.first else { throw BERError.truncated }
            var index = bytes.index(after: bytes.startIndex)
            guard index < bytes.endIndex else { throw BERError.truncated }
            var count = Int(bytes[index])
            index += 1
            if count & 0x80 != 0 {
                let lengthBytes = count & 0x7F
                guard lengthBytes > 0, lengthBytes <= 4, index + lengthBytes <= bytes.endIndex else { throw BERError.invalid("length") }
                count = bytes[index..<(index + lengthBytes)].reduce(0) { $0 << 8 | Int($1) }
                index += lengthBytes
            }
            guard index + count <= bytes.endIndex else { throw BERError.truncated }
            let content = bytes[index..<(index + count)]
            bytes = bytes[(index + count)...]
            return (tag, content)
        }

        mutating func read(expecting tag: UInt8) throws -> ArraySlice<UInt8> {
            let item = try read()
            guard item.tag == tag else { throw BERError.unexpectedTag(item.tag) }
            return item.content
        }

        mutating func readInteger() throws -> Int64 {
            try BER.decodeInteger(try read(expecting: Tag.integer))
        }

        mutating func readOctets() throws -> ArraySlice<UInt8> {
            try read(expecting: Tag.octetString)
        }

        mutating func readSequence(tag: UInt8 = Tag.sequence) throws -> Reader {
            Reader(try read(expecting: tag))
        }
    }

    static func decodeInteger(_ content: ArraySlice<UInt8>) throws -> Int64 {
        guard !content.isEmpty, content.count <= 8 else { throw BERError.invalid("integer") }
        var value: Int64 = content.first! & 0x80 != 0 ? -1 : 0
        for byte in content { value = value << 8 | Int64(byte) }
        return value
    }

    static func decodeUnsigned(_ content: ArraySlice<UInt8>) throws -> UInt64 {
        guard !content.isEmpty, content.count <= 9 else { throw BERError.invalid("unsigned") }
        return content.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func decodeOID(_ content: ArraySlice<UInt8>) throws -> OID {
        var subidentifiers: [UInt32] = []
        var current: UInt32 = 0
        for byte in content {
            guard current < (1 << 25) else { throw BERError.invalid("oid component") }
            current = current << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 {
                subidentifiers.append(current)
                current = 0
            }
        }
        guard let first = subidentifiers.first else { throw BERError.invalid("oid") }
        let arc = min(first / 40, 2)
        return OID([arc, first - arc * 40] + subidentifiers.dropFirst())
    }

    static func decodeValue(tag: UInt8, content: ArraySlice<UInt8>) throws -> SNMPValue {
        switch tag {
        case Tag.integer: return .integer(try decodeInteger(content))
        case Tag.octetString: return .octets(Array(content))
        case Tag.null: return .null
        case Tag.oid: return .oid(try decodeOID(content))
        case Tag.ipAddress:
            guard content.count == 4 else { throw BERError.invalid("ipAddress") }
            return .ipAddress(IPv4Address(content.reduce(0) { $0 << 8 | UInt32($1) }))
        case Tag.counter32: return .counter32(UInt32(truncatingIfNeeded: try decodeUnsigned(content)))
        case Tag.gauge32: return .gauge32(UInt32(truncatingIfNeeded: try decodeUnsigned(content)))
        case Tag.timeTicks: return .timeTicks(UInt32(truncatingIfNeeded: try decodeUnsigned(content)))
        case Tag.opaque: return .opaque(Array(content))
        case Tag.counter64: return .counter64(try decodeUnsigned(content))
        case Tag.noSuchObject: return .noSuchObject
        case Tag.noSuchInstance: return .noSuchInstance
        case Tag.endOfMibView: return .endOfMibView
        default: throw BERError.unexpectedTag(tag)
        }
    }
}
