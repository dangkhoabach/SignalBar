import Foundation
import Testing
@testable import SignalBarCore

private func hex(_ text: String) -> [UInt8] {
    let digits = text.replacingOccurrences(of: " ", with: "")
    return stride(from: 0, to: digits.count, by: 2).map {
        let start = digits.index(digits.startIndex, offsetBy: $0)
        return UInt8(digits[start..<digits.index(start, offsetBy: 2)], radix: 16)!
    }
}

@Suite struct BERTests {
    @Test func integersUseTheShortestTwosComplement() throws {
        #expect(BER.integer(0) == [0x02, 0x01, 0x00])
        #expect(BER.integer(127) == [0x02, 0x01, 0x7F])
        #expect(BER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(BER.integer(-1) == [0x02, 0x01, 0xFF])
        #expect(BER.integer(-129) == [0x02, 0x02, 0xFF, 0x7F])
        #expect(BER.integer(65_507) == [0x02, 0x03, 0x00, 0xFF, 0xE3])
        for value: Int64 in [0, 1, -1, 127, 128, -128, -129, 65_535, Int64(Int32.max), Int64(Int32.min)] {
            var reader = BER.Reader(BER.integer(value)[...])
            #expect(try reader.readInteger() == value)
        }
    }

    @Test func longLengthsRoundTrip() throws {
        let content = [UInt8](repeating: 7, count: 300)
        let encoded = BER.octets(content)
        #expect(Array(encoded.prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
        var reader = BER.Reader(encoded[...])
        #expect(Array(try reader.readOctets()) == content)
    }

    @Test func oidsRoundTripIncludingLargeComponents() throws {
        for oid: OID in ["1.3.6.1.2.1.1.5.0", "1.3.6.1.4.1.311.1", "1.3.6.1.4.1.2636.3.1.13", "2.999.3", "1.3.6.1.2.1.17.7.1.2.2.1.2.20.170.187.204.221.238.255"] {
            var reader = BER.Reader(BER.oid(oid)[...])
            #expect(try BER.decodeOID(try reader.read(expecting: BER.Tag.oid)) == oid)
        }
        #expect(BER.oid("1.3.6.1.4.1.311") == [0x06, 0x07, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37])
    }

    @Test func everyValueTypeRoundTrips() throws {
        let values: [SNMPValue] = [
            .integer(-42), .octets([1, 2, 3]), .null, .oid("1.3.6.1"), .ipAddress(IPv4Address("10.0.0.1")!),
            .counter32(UInt32.max), .gauge32(1_000), .timeTicks(123_456), .counter64(UInt64.max),
            .opaque([9]), .noSuchObject, .noSuchInstance, .endOfMibView,
        ]
        for value in values {
            var reader = BER.Reader(BER.value(value)[...])
            let (tag, content) = try reader.read()
            #expect(try BER.decodeValue(tag: tag, content: content) == value)
        }
    }

    @Test func truncatedInputThrowsInsteadOfCrashing() {
        var reader = BER.Reader([0x04, 0x05, 0x01][...])
        #expect(throws: BERError.self) { try reader.read() }
        var empty = BER.Reader([][...])
        #expect(throws: BERError.self) { try empty.read() }
    }

    @Test func oidOrderingIsLexicographic() {
        #expect(OID("1.3.6.1.2") < OID("1.3.6.1.10"))
        #expect(OID("1.3.6.1") < OID("1.3.6.1.0"))
        #expect(OID("1.3.6.1").isPrefix(of: "1.3.6.1.5"))
        #expect(!OID("1.3.6.1").isPrefix(of: "1.3.6.1"))
        #expect(!OID("1.3.6.1.2").isPrefix(of: "1.3.6.1.20"))
    }
}

@Suite struct SNMPMessageTests {
    @Test func v2cMessagesRoundTrip() throws {
        let pdu = SNMPPDU(kind: .response, requestID: 77, errorStatus: 0, errorIndex: 0, bindings: [
            SNMPVarBind(oid: "1.3.6.1.2.1.1.5.0", value: .octets(Array("core-sw".utf8))),
            SNMPVarBind(oid: "1.3.6.1.2.1.1.3.0", value: .timeTicks(999)),
        ])
        let decoded = try SNMPv2cMessage.decode(SNMPv2cMessage.encode(community: "public", pdu: pdu))
        #expect(decoded == pdu)
    }

    /// RFC 3414 appendix A.3: the published password-to-key results.
    @Test func keyLocalisationMatchesRFC3414() {
        let engineID = hex("000000000000000000000002")
        let md5 = USM.passwordToKey("maplesyrup", auth: .md5)
        #expect(md5 == hex("9faf3283884e92834ebc9847d8edd963"))
        #expect(USM.localize(md5, engineID: engineID, auth: .md5) == hex("526f5eed9fcce26f8964c2930787d82b"))
        let sha = USM.passwordToKey("maplesyrup", auth: .sha1)
        #expect(sha == hex("9fb5cc0381497b3793528939ff788d5d79145211"))
        #expect(USM.localize(sha, engineID: engineID, auth: .sha1) == hex("6695febc9288e36282235fc7151f128497b38f3f"))
    }

    private func v3Message(flags: SNMPv3Message.Flags) -> SNMPv3Message {
        SNMPv3Message(
            messageID: 4242, flags: flags,
            security: USMParameters(engineID: hex("80001f8880aabbccdd"), engineBoots: 3, engineTime: 98_765, userName: "monitor",
                                    authParameters: [], privParameters: []),
            contextEngineID: hex("80001f8880aabbccdd"),
            pdu: SNMPPDU(kind: .get, requestID: 9, errorStatus: 0, errorIndex: 0, bindings: [SNMPVarBind(oid: "1.3.6.1.2.1.1.5.0", value: .null)])
        )
    }

    @Test func signedAndEncryptedMessagesRoundTripForEveryAuthProtocol() throws {
        for auth in SNMPAuthProtocol.allCases {
            let credentials = SNMPCredentials.v3(user: "monitor", auth: auth, authPassword: "auth-secret", priv: .aes128, privPassword: "priv-secret")
            let keys = USMKeys(credentials: credentials, engineID: hex("80001f8880aabbccdd"))
            let message = v3Message(flags: [.auth, .priv, .reportable])
            let bytes = try #require(message.encode(keys: keys, salt: [1, 2, 3, 4, 5, 6, 7, 8]))
            // The PDU's OID must not appear in the clear on the wire.
            #expect(bytes.firstRange(of: BER.oid("1.3.6.1.2.1.1.5.0")) == nil)
            let decoded = try SNMPv3Message.decode(bytes, keys: keys)
            #expect(decoded.pdu == message.pdu, "\(auth)")
            #expect(decoded.security.userName == "monitor")
            #expect(decoded.flags.contains(.priv))
        }
    }

    @Test func aWrongPasswordIsCaughtAsSuch() throws {
        let engine = hex("80001f8880aabbccdd")
        let right = USMKeys(credentials: .v3(user: "monitor", auth: .sha1, authPassword: "auth-secret", priv: .aes128, privPassword: "priv-secret"), engineID: engine)
        let wrongAuth = USMKeys(credentials: .v3(user: "monitor", auth: .sha1, authPassword: "not-it-at-all", priv: .aes128, privPassword: "priv-secret"), engineID: engine)
        let bytes = try #require(v3Message(flags: [.auth, .priv]).encode(keys: right, salt: [1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(throws: SNMPv3Message.DecodeFailure.wrongDigest) { try SNMPv3Message.decode(bytes, keys: wrongAuth) }

        var tampered = bytes
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: SNMPv3Message.DecodeFailure.wrongDigest) { try SNMPv3Message.decode(tampered, keys: right) }
    }

    @Test func discoveryProbeIsUnauthenticatedAndReportable() throws {
        let probe = SNMPv3Message(
            messageID: 1, flags: [.reportable],
            security: USMParameters(engineID: [], engineBoots: 0, engineTime: 0, userName: "", authParameters: [], privParameters: []),
            contextEngineID: [], pdu: SNMPPDU(kind: .get, requestID: 2, errorStatus: 0, errorIndex: 0, bindings: [])
        )
        let decoded = try SNMPv3Message.decode(try #require(probe.encode(keys: nil, salt: [])), keys: nil)
        #expect(decoded.flags == [.reportable])
        #expect(decoded.security.engineID.isEmpty)
    }
}

@Suite struct SNMPCollectorTests {
    @Test func readsIPv4RowsOfTheARPTables() {
        let physical = [
            SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 4, 35, 1, 4, 12, 1, 4, 10, 0, 20, 5]), value: .octets([0xA4, 0x83, 0xE7, 1, 2, 3])),
            // IPv6 row: skipped.
            SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 4, 35, 1, 4, 12, 2, 16] + Array(repeating: 0, count: 16)), value: .octets([0xA4, 0x83, 0xE7, 1, 2, 4])),
            // Incomplete entry with an all-zero MAC: skipped.
            SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 4, 35, 1, 4, 12, 1, 4, 10, 0, 20, 6]), value: .octets([0, 0, 0, 0, 0, 0])),
        ]
        let entries = SNMPCollector.parseARPPhysical(physical)
        #expect(entries == [SNMPARPEntry(ip: IPv4Address("10.0.20.5")!, mac: MACAddress("a4:83:e7:01:02:03")!, interfaceIndex: 12)])

        let media = [SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 4, 22, 1, 2, 7, 10, 0, 30, 9]), value: .octets([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]))]
        #expect(SNMPCollector.parseARPMedia(media) == [SNMPARPEntry(ip: IPv4Address("10.0.30.9")!, mac: MACAddress("00:11:22:33:44:55")!, interfaceIndex: 7)])
    }

    @Test func readsTheMACTableWithVLANsAndPorts() {
        let basePorts = SNMPCollector.parseBasePorts([SNMPVarBind(oid: "1.3.6.1.2.1.17.1.4.1.2.3", value: .integer(10_003))])
        let rows = [
            SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 17, 7, 1, 2, 2, 1, 2, 20, 0xA4, 0x83, 0xE7, 1, 2, 3]), value: .integer(3)),
            // Port 0: the switch's own MAC, not a device.
            SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 17, 7, 1, 2, 2, 1, 2, 1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55]), value: .integer(0)),
        ]
        let table = SNMPCollector.parseQBridgeFDB(rows, basePorts: basePorts)
        #expect(table == [SNMPMACTableEntry(mac: MACAddress("a4:83:e7:01:02:03")!, vlanID: 20, interfaceIndex: 10_003)])

        let bridge = [SNMPVarBind(oid: OID([1, 3, 6, 1, 2, 1, 17, 4, 3, 1, 2, 0xA4, 0x83, 0xE7, 1, 2, 3]), value: .integer(3))]
        #expect(SNMPCollector.parseBridgeFDB(bridge, basePorts: basePorts) ==
                [SNMPMACTableEntry(mac: MACAddress("a4:83:e7:01:02:03")!, vlanID: nil, interfaceIndex: 10_003)])
    }

    @Test func uplinkPortsAreNotWhereADeviceIsPlugged() {
        let access = SNMPMACTableEntry(mac: MACAddress("a4:83:e7:00:00:01")!, vlanID: 10, interfaceIndex: 1)
        let uplink = (2...9).map { SNMPMACTableEntry(mac: MACAddress("a4:83:e7:00:00:0\($0)")!, vlanID: 10, interfaceIndex: 24) }
        let ports = SNMPCollector.accessPorts([access] + uplink)
        #expect(ports.keys.map(\.description) == ["a4:83:e7:00:00:01"])
    }

    @Test func routerAddressesBecomeSubnetSuggestions() {
        let rows = [
            SNMPVarBind(oid: "1.3.6.1.2.1.4.20.1.3.10.0.20.1", value: .ipAddress(IPv4Address("255.255.255.0")!)),
            SNMPVarBind(oid: "1.3.6.1.2.1.4.20.1.3.10.0.30.1", value: .ipAddress(IPv4Address("255.255.254.0")!)),
            // Loopback and a public uplink: not subnets to manage.
            SNMPVarBind(oid: "1.3.6.1.2.1.4.20.1.3.127.0.0.1", value: .ipAddress(IPv4Address("255.0.0.0")!)),
            SNMPVarBind(oid: "1.3.6.1.2.1.4.20.1.3.203.0.113.2", value: .ipAddress(IPv4Address("255.255.255.252")!)),
        ]
        #expect(SNMPCollector.parseNetworks(rows).map(\.description) == ["10.0.20.0/24", "10.0.30.0/23"])
    }
}
