import CommonCrypto
import CryptoKit
import Foundation

public struct SNMPVarBind: Sendable, Equatable {
    public let oid: OID
    public let value: SNMPValue

    public init(oid: OID, value: SNMPValue) {
        self.oid = oid
        self.value = value
    }
}

/// A protocol data unit: the request or response inside any SNMP message.
/// For GETBULK the two error fields carry non-repeaters and max-repetitions.
struct SNMPPDU: Equatable {
    enum Kind: UInt8 {
        case get = 0xA0
        case getNext = 0xA1
        case response = 0xA2
        case getBulk = 0xA5
        case report = 0xA8
    }

    var kind: Kind
    var requestID: Int32
    var errorStatus: Int
    var errorIndex: Int
    var bindings: [SNMPVarBind]

    func encode() -> [UInt8] {
        let list = BER.sequence(bindings.map { BER.sequence([BER.oid($0.oid), BER.value($0.value)]) })
        return BER.sequence([
            BER.integer(Int64(requestID)), BER.integer(Int64(errorStatus)), BER.integer(Int64(errorIndex)), list,
        ], tag: kind.rawValue)
    }

    static func decode(tag: UInt8, content: ArraySlice<UInt8>) throws -> SNMPPDU {
        guard let kind = Kind(rawValue: tag) else { throw BERError.unexpectedTag(tag) }
        var reader = BER.Reader(content)
        let requestID = Int32(truncatingIfNeeded: try reader.readInteger())
        let errorStatus = Int(try reader.readInteger())
        let errorIndex = Int(try reader.readInteger())
        var list = try reader.readSequence()
        var bindings: [SNMPVarBind] = []
        while !list.isAtEnd {
            var binding = try list.readSequence()
            let oid = try BER.decodeOID(try binding.read(expecting: BER.Tag.oid))
            let (tag, valueContent) = try binding.read()
            bindings.append(SNMPVarBind(oid: oid, value: try BER.decodeValue(tag: tag, content: valueContent)))
        }
        return SNMPPDU(kind: kind, requestID: requestID, errorStatus: errorStatus, errorIndex: errorIndex, bindings: bindings)
    }
}

// MARK: - SNMPv2c

enum SNMPv2cMessage {
    static func encode(community: String, pdu: SNMPPDU) -> [UInt8] {
        BER.sequence([BER.integer(1), BER.octets(Array(community.utf8)), pdu.encode()])
    }

    static func decode(_ bytes: [UInt8]) throws -> SNMPPDU {
        var outer = BER.Reader(bytes[...])
        var message = try outer.readSequence()
        guard try message.readInteger() == 1 else { throw BERError.invalid("version") }
        _ = try message.readOctets()
        let (tag, content) = try message.read()
        return try SNMPPDU.decode(tag: tag, content: content)
    }
}

// MARK: - SNMPv3 / USM (RFC 3414, 3826, 7860)

public enum SNMPAuthProtocol: String, Sendable, Codable, CaseIterable {
    case md5, sha1, sha256

    /// Length of the truncated HMAC carried in the message.
    var digestLength: Int { self == .sha256 ? 24 : 12 }
}

public enum SNMPPrivProtocol: String, Sendable, Codable, CaseIterable {
    case aes128
}

/// The user-based security model's parameters, as carried in a message.
struct USMParameters: Equatable {
    var engineID: [UInt8]
    var engineBoots: Int64
    var engineTime: Int64
    var userName: String
    var authParameters: [UInt8]
    var privParameters: [UInt8]
}

struct SNMPv3Message {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let auth = Flags(rawValue: 1)
        static let priv = Flags(rawValue: 2)
        static let reportable = Flags(rawValue: 4)
    }

    var messageID: Int32
    var flags: Flags
    var security: USMParameters
    var contextEngineID: [UInt8]
    var pdu: SNMPPDU
}

enum USM {
    /// RFC 3414 A.2: the password repeated to fill one megabyte, hashed.
    static func passwordToKey(_ password: String, auth: SNMPAuthProtocol) -> [UInt8] {
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty else { return [] }
        var chunk = [UInt8](repeating: 0, count: 64)
        var index = 0
        func fill() {
            for position in 0..<64 {
                chunk[position] = bytes[index % bytes.count]
                index += 1
            }
        }
        func run<H: HashFunction>(_ hasher: inout H) {
            for _ in 0..<(1_048_576 / 64) {
                fill()
                hasher.update(data: chunk)
            }
        }
        switch auth {
        case .md5:
            var hasher = Insecure.MD5()
            run(&hasher)
            return Array(hasher.finalize())
        case .sha1:
            var hasher = Insecure.SHA1()
            run(&hasher)
            return Array(hasher.finalize())
        case .sha256:
            var hasher = SHA256()
            run(&hasher)
            return Array(hasher.finalize())
        }
    }

    /// RFC 3414 A.2.2: ties the key to one engine, `H(Ku || engineID || Ku)`.
    static func localize(_ key: [UInt8], engineID: [UInt8], auth: SNMPAuthProtocol) -> [UInt8] {
        let input = key + engineID + key
        switch auth {
        case .md5: return Array(Insecure.MD5.hash(data: input))
        case .sha1: return Array(Insecure.SHA1.hash(data: input))
        case .sha256: return Array(SHA256.hash(data: input))
        }
    }

    static func digest(_ message: [UInt8], key: [UInt8], auth: SNMPAuthProtocol) -> [UInt8] {
        let symmetric = SymmetricKey(data: key)
        let mac: [UInt8] = switch auth {
        case .md5: Array(HMAC<Insecure.MD5>.authenticationCode(for: message, using: symmetric))
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        }
        return Array(mac.prefix(auth.digestLength))
    }

    /// RFC 3826: AES-128 in 128-bit CFB mode, IV = boots ‖ time ‖ salt.
    static func aesCFB(_ data: [UInt8], key: [UInt8], engineBoots: Int64, engineTime: Int64, salt: [UInt8], encrypt: Bool) -> [UInt8]? {
        guard key.count >= 16, salt.count == 8 else { return nil }
        let iv = withUnsafeBytes(of: UInt32(truncatingIfNeeded: engineBoots).bigEndian, Array.init)
            + withUnsafeBytes(of: UInt32(truncatingIfNeeded: engineTime).bigEndian, Array.init) + salt
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, Array(key.prefix(16)), 16, nil, 0, 0, CCModeOptions(0), &cryptor
        )
        guard created == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, data, data.count, &output, output.count, &moved) == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}

/// Keys for one user against one engine, worked out once (the password
/// hashing is a megabyte of work) and reused for every message.
struct USMKeys {
    let auth: SNMPAuthProtocol?
    let authKey: [UInt8]
    let priv: SNMPPrivProtocol?
    let privKey: [UInt8]

    init(credentials: SNMPCredentials, engineID: [UInt8]) {
        auth = credentials.authProtocol
        priv = credentials.authProtocol == nil ? nil : credentials.privProtocol
        if let auth {
            authKey = USM.localize(USM.passwordToKey(credentials.authPassword, auth: auth), engineID: engineID, auth: auth)
            privKey = priv == nil ? [] : USM.localize(USM.passwordToKey(credentials.privPassword, auth: auth), engineID: engineID, auth: auth)
        } else {
            authKey = []
            privKey = []
        }
    }
}

extension SNMPv3Message {
    static func scopedPDU(contextEngineID: [UInt8], pdu: SNMPPDU) -> [UInt8] {
        BER.sequence([BER.octets(contextEngineID), BER.octets([]), pdu.encode()])
    }

    /// Builds the wire bytes. With keys, the PDU is encrypted when `priv` is
    /// set and the message signed when `auth` is.
    func encode(keys: USMKeys?, salt: [UInt8]) -> [UInt8]? {
        var flags = flags
        var privParameters: [UInt8] = []
        var data = Self.scopedPDU(contextEngineID: contextEngineID, pdu: pdu)
        if let keys, keys.priv != nil, flags.contains(.priv) {
            guard let encrypted = USM.aesCFB(data, key: keys.privKey, engineBoots: security.engineBoots,
                                             engineTime: security.engineTime, salt: salt, encrypt: true)
            else { return nil }
            data = BER.octets(encrypted)
            privParameters = salt
        } else {
            flags.remove(.priv)
        }
        let digestLength = keys?.auth?.digestLength ?? 0
        if digestLength == 0 { flags.remove(.auth) }

        let global = BER.sequence([
            BER.integer(Int64(messageID)), BER.integer(65_507), BER.octets([flags.rawValue]), BER.integer(3),
        ])
        let securityHead = BER.octets(security.engineID) + BER.integer(security.engineBoots)
            + BER.integer(security.engineTime) + BER.octets(Array(security.userName.utf8))
        let authHeader = [BER.Tag.octetString] + BER.length(digestLength)
        let securityBody = securityHead + authHeader + [UInt8](repeating: 0, count: digestLength) + BER.octets(privParameters)
        let securitySequence = BER.tlv(BER.Tag.sequence, securityBody)
        let securityOctets = BER.tlv(BER.Tag.octetString, securitySequence)
        let body = BER.integer(3) + global + securityOctets + data
        var message = BER.tlv(BER.Tag.sequence, body)

        if let keys, let auth = keys.auth, digestLength > 0 {
            let offset = (message.count - body.count) + BER.integer(3).count + global.count
                + (securityOctets.count - securitySequence.count) + (securitySequence.count - securityBody.count)
                + securityHead.count + authHeader.count
            let digest = USM.digest(message, key: keys.authKey, auth: auth)
            message.replaceSubrange(offset..<(offset + digestLength), with: digest)
        }
        return message
    }

    enum DecodeFailure: Error, Equatable {
        case wrongDigest
        case decryption
    }

    /// Parses a received message. With keys, a signed message is verified
    /// and an encrypted one decrypted; without, both are rejected.
    static func decode(_ bytes: [UInt8], keys: USMKeys?) throws -> SNMPv3Message {
        var outer = BER.Reader(bytes[...])
        var message = try outer.readSequence()
        guard try message.readInteger() == 3 else { throw BERError.invalid("version") }
        var global = try message.readSequence()
        let messageID = Int32(truncatingIfNeeded: try global.readInteger())
        _ = try global.readInteger()
        let flags = Flags(rawValue: try global.readOctets().first ?? 0)

        var securityReader = BER.Reader(try message.readOctets())
        var security = try securityReader.readSequence()
        let engineID = Array(try security.readOctets())
        let boots = try security.readInteger()
        let time = try security.readInteger()
        let user = String(decoding: try security.readOctets(), as: UTF8.self)
        let authSlice = try security.readOctets()
        let privParameters = Array(try security.readOctets())
        let usm = USMParameters(engineID: engineID, engineBoots: boots, engineTime: time, userName: user,
                                authParameters: Array(authSlice), privParameters: privParameters)

        if flags.contains(.auth) {
            guard let keys, let auth = keys.auth, authSlice.count == auth.digestLength else { throw DecodeFailure.wrongDigest }
            var zeroed = bytes
            zeroed.replaceSubrange(authSlice.indices, with: [UInt8](repeating: 0, count: authSlice.count))
            guard USM.digest(zeroed, key: keys.authKey, auth: auth) == Array(authSlice) else { throw DecodeFailure.wrongDigest }
        }

        var scoped: BER.Reader
        if flags.contains(.priv) {
            guard let keys, keys.priv != nil,
                  let plain = USM.aesCFB(Array(try message.readOctets()), key: keys.privKey, engineBoots: boots,
                                         engineTime: time, salt: privParameters, encrypt: false)
            else { throw DecodeFailure.decryption }
            var decrypted = BER.Reader(plain[...])
            guard let inner = try? decrypted.readSequence() else { throw DecodeFailure.decryption }
            scoped = inner
        } else {
            scoped = try message.readSequence()
        }
        let contextEngineID = Array(try scoped.readOctets())
        _ = try scoped.readOctets()
        let (tag, content) = try scoped.read()
        return SNMPv3Message(
            messageID: messageID, flags: flags, security: usm, contextEngineID: contextEngineID,
            pdu: try SNMPPDU.decode(tag: tag, content: content)
        )
    }
}
