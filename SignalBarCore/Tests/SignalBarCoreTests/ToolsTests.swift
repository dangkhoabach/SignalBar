import Foundation
import Testing
@testable import SignalBarCore

@Suite struct EchoParsingTests {
    private let id: UInt16 = 0xBEEF

    private func ipv4Header(ttl: UInt8 = 57) -> [UInt8] {
        [0x45, 0, 0, 0, 0, 0, 0, 0, ttl] + Array(repeating: 0, count: 11)
    }

    @Test func anIPv4EchoCarriesAValidChecksumAndCountingBytes() {
        let packet = EchoSocket.echoRequest(family: .ipv4, identifier: id, sequence: 7, payloadSize: 56)
        #expect(packet.count == 64)
        #expect(Array(packet[0..<2]) == [8, 0])
        #expect(Array(packet[4..<8]) == [0xBE, 0xEF, 0, 7])
        #expect(Array(packet[8..<12]) == [0, 1, 2, 3])
        // A correct checksum makes the whole message sum to zero.
        #expect(HostSweep.internetChecksum(packet) == 0)
        #expect(EchoSocket.echoRequest(family: .ipv6, identifier: id, sequence: 7, payloadSize: 0)[0] == 128)
    }

    @Test func ipv4RepliesAndErrorsAreMatchedToOurEcho() {
        let echo = EchoSocket.echoRequest(family: .ipv4, identifier: id, sequence: 3, payloadSize: 8)
        var reply = echo
        reply[0] = 0
        #expect(EchoSocket.parse((ipv4Header() + reply)[...], family: .ipv4, identifier: id) == .reply(sequence: 3, ttl: 57))
        #expect(EchoSocket.parse((ipv4Header() + reply)[...], family: .ipv4, identifier: 0x1234) == nil)

        let exceeded = ipv4Header() + [11, 0, 0, 0, 0, 0, 0, 0] + ipv4Header() + echo
        #expect(EchoSocket.parse(exceeded[...], family: .ipv4, identifier: id) == .timeExceeded(sequence: 3))
        let unreachable = ipv4Header() + [3, 1, 0, 0, 0, 0, 0, 0] + ipv4Header() + echo
        #expect(EchoSocket.parse(unreachable[...], family: .ipv4, identifier: id) == .unreachable(sequence: 3))
    }

    @Test func ipv6MessagesComeWithoutAnOuterHeader() {
        let echo = EchoSocket.echoRequest(family: .ipv6, identifier: id, sequence: 9, payloadSize: 8)
        var reply = echo
        reply[0] = 129
        #expect(EchoSocket.parse(reply[...], family: .ipv6, identifier: id) == .reply(sequence: 9, ttl: nil))
        let innerHeader: [UInt8] = [0x60] + Array(repeating: 0, count: 39)
        let exceeded: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 0] + innerHeader + echo
        #expect(EchoSocket.parse(exceeded[...], family: .ipv6, identifier: id) == .timeExceeded(sequence: 9))
        let unreachable: [UInt8] = [1, 4, 0, 0, 0, 0, 0, 0] + innerHeader + echo
        #expect(EchoSocket.parse(unreachable[...], family: .ipv6, identifier: id) == .unreachable(sequence: 9))
    }
}

@Suite struct PingAndTraceTests {
    @Test func pingStatisticsCountTimeouts() {
        let replies = [PingReply(sequence: 0, milliseconds: 10), PingReply(sequence: 1), PingReply(sequence: 2, milliseconds: 20),
                       PingReply(sequence: 3, milliseconds: 30)]
        let stats = PingStatistics(replies)
        #expect(stats.sent == 4)
        #expect(stats.received == 3)
        #expect(stats.lossPercent == 25)
        #expect(stats.minimum == 10)
        #expect(stats.maximum == 30)
        #expect(stats.average == 20)
        #expect(abs((stats.standardDeviation ?? 0) - 8.165) < 0.001)
        #expect(PingStatistics([]).average == nil)
    }

    @Test func sequenceNumbersSurviveThe16BitWrap() {
        #expect(Ping.fullSequence(5, near: 6) == 5)
        #expect(Ping.fullSequence(0xFFFF, near: 0x10001) == 0xFFFF)
        #expect(Ping.fullSequence(1, near: 0x10002) == 0x10001)
    }

    private func probe(_ ttl: Int, _ address: String?, _ ms: Double? = 10, destination: Bool = false, unreachable: Bool = false) -> TraceProbe {
        TraceProbe(ttl: ttl, from: address.flatMap(ToolAddress.init), milliseconds: address == nil ? nil : ms,
                   reachedDestination: destination, unreachable: unreachable)
    }

    @Test func roundsFoldIntoHopsEndingAtTheDestination() {
        var summary = TraceSummary()
        // TTLs past the destination are answered by the destination too.
        summary.add(round: [probe(1, "192.0.2.1", 2), probe(2, nil), probe(3, "203.0.113.9", 30, destination: true),
                            probe(4, "203.0.113.9", 31, destination: true)])
        summary.add(round: [probe(1, "192.0.2.1", 4), probe(2, "198.51.100.1", 12), probe(3, "203.0.113.9", 34, destination: true)])
        #expect(summary.destinationTTL == 3)
        #expect(summary.hops.map(\.ttl) == [1, 2, 3])
        #expect(summary.hops[0].average == 3)
        #expect(summary.hops[0].best == 2)
        #expect(summary.hops[0].worst == 4)
        #expect(summary.hops[1].lossPercent == 50)
        #expect(summary.hops[2].received == 2)
    }

    @Test func aLoadBalancedHopListsItsMostFrequentAddressFirst() {
        var summary = TraceSummary()
        for address in ["198.51.100.2", "198.51.100.1", "198.51.100.1"] {
            summary.add(round: [probe(1, address), probe(2, "203.0.113.9", destination: true)])
        }
        #expect(summary.hops[0].addresses.map(\.description) == ["198.51.100.1", "198.51.100.2"])
    }

    @Test func withoutTheDestinationTheListStopsOneSilentHopPastTheLastAnswer() {
        var summary = TraceSummary()
        summary.add(round: [probe(1, "192.0.2.1"), probe(2, "198.51.100.1"), probe(3, nil), probe(4, nil), probe(5, nil)])
        #expect(summary.hops.map(\.ttl) == [1, 2, 3])
        #expect(!summary.reachedDestination)

        var blocked = TraceSummary()
        blocked.add(round: [probe(1, "192.0.2.1"), probe(2, "198.51.100.1", unreachable: true), probe(3, nil)])
        #expect(blocked.hops.map(\.ttl) == [1, 2])
        #expect(blocked.hops.last?.unreachable == true)
    }
}

@Suite struct DNSLookupTests {
    /// A response to `query`, with these answer records appended (name as a pointer to the question).
    private func response(to query: [UInt8], rcode: UInt8 = 0, answers: [(type: UInt16, ttl: UInt32, data: [UInt8])]) -> [UInt8] {
        var message = query
        message[2] = 0x81
        message[3] = 0x80 | rcode
        message[7] = UInt8(answers.count)
        for answer in answers {
            message += [0xC0, 12, UInt8(answer.type >> 8), UInt8(answer.type & 0xFF), 0, 1]
            message += withUnsafeBytes(of: answer.ttl.bigEndian) { Array($0) }
            message += [UInt8(answer.data.count >> 8), UInt8(answer.data.count & 0xFF)] + answer.data
        }
        return message
    }

    private func name(_ text: String) -> [UInt8] {
        text.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    @Test func everyRecordTypeReadsLikeDig() throws {
        let withEDNS = DNSMessage.query("example.com", type: 15, id: 7, edns: true)
        #expect(withEDNS[11] == 1)
        #expect(Array(withEDNS.suffix(11)) == [0, 0, 41, 0x10, 0x00, 0, 0, 0, 0, 0, 0])

        let reply = response(to: DNSMessage.query("example.com", type: 15, id: 7), answers: [
            (1, 300, [192, 0, 2, 7]),
            (28, 300, [0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1]),
            (15, 3600, [0, 10] + name("mail.example.com")),
            (16, 60, [5] + Array("hello".utf8) + [3] + Array("a b".utf8)),
            (6, 900, name("ns1.example.com") + name("admin.example.com") + [0, 0, 0, 1, 0, 0, 0x0E, 0x10, 0, 0, 0x07, 0x08, 0, 0x12, 0x75, 0, 0, 0, 0x01, 0x2C]),
            (33, 60, [0, 10, 0, 5, 0x13, 0xC4] + name("sip.example.com")),
            (257, 60, [0, 5] + Array("issue".utf8) + Array("ca.example".utf8)),
            (5, 60, [0xC0, 12]),
            (99, 60, [0xAB, 0xCD]),
        ])
        let result = try #require(DNSLookup.parse(reply, server: "192.0.2.53", milliseconds: 12))
        #expect(result.rcodeName == "NOERROR")
        #expect(result.recursionAvailable)
        #expect(result.answers.map(\.type) == ["A", "AAAA", "MX", "TXT", "SOA", "SRV", "CAA", "CNAME", "TYPE99"])
        #expect(result.answers.map(\.value) == [
            "192.0.2.7", "2001:db8::1", "10 mail.example.com", "\"hello\" \"a b\"",
            "ns1.example.com admin.example.com 1 3600 1800 1209600 300", "10 5 5060 sip.example.com",
            "0 issue \"ca.example\"", "example.com", "\\# 2 abcd",
        ])
        #expect(result.answers[0].ttl == 300)
        #expect(result.answers[0].name == "example.com")
    }

    @Test func aMissingNameSaysSo() throws {
        let reply = response(to: DNSMessage.query("nope.example", type: 1, id: 9, edns: false), rcode: 3, answers: [])
        #expect(try #require(DNSLookup.parse(reply, server: "192.0.2.53", milliseconds: 1)).rcodeName == "NXDOMAIN")
        #expect(DNSLookup.parse([0, 1, 2], server: "x", milliseconds: 0) == nil)
    }

    @Test func anAddressIsLookedUpByItsReverseName() {
        #expect(DNSLookup.queryName(for: "192.0.2.7") == ("7.2.0.192.in-addr.arpa", true))
        #expect(DNSLookup.queryName(for: "2001:db8::1").name
            == "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")
        #expect(DNSLookup.queryName(for: "https://www.example.com/path") == ("www.example.com", false))
        #expect(DNSLookup.queryName(for: "example.com.") == ("example.com", false))
    }
}

@Suite struct ToolInputTests {
    @Test func theHostIsTakenFromWhateverWasPasted() {
        #expect(ToolTarget.host(from: " example.com ") == "example.com")
        #expect(ToolTarget.host(from: "https://example.com:8443/a?b") == "example.com")
        #expect(ToolTarget.host(from: "example.com/path") == "example.com")
        #expect(ToolTarget.host(from: "[2001:db8::1]") == "2001:db8::1")
        #expect(ToolAddress("2001:db8::1")?.family == .ipv6)
        #expect(ToolAddress("192.0.2.1")?.description == "192.0.2.1")
        #expect(ToolAddress("example.com") == nil)
    }

    @Test func portListsTakeSinglesAndRangesWithinLimits() {
        #expect(PortCheck.parse("22, 80 443") == [22, 80, 443])
        #expect(PortCheck.parse("8000-8003,22,22") == [22, 8000, 8001, 8002, 8003])
        #expect(PortCheck.parse("0, 70000, abc, 5-3") == [])
        #expect(PortCheck.parse("1-65535").count == PortCheck.maxPorts)
    }

    @Test func whoisNeverGetsSomethingItCouldReadAsAnOption() {
        #expect(Whois.isValidQuery("example.com"))
        #expect(Whois.isValidQuery("2001:db8::1"))
        #expect(Whois.isValidQuery("AS13335"))
        #expect(!Whois.isValidQuery("-h evil.example"))
        #expect(!Whois.isValidQuery("example.com; rm"))
        #expect(!Whois.isValidQuery(""))
    }

    @Test func aMagicPacketIsSixFFsThenTheMACSixteenTimes() throws {
        let mac = try #require(MACAddress("00:11:22:33:44:55"))
        let packet = WakeOnLAN.magicPacket(for: mac)
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == Array(repeating: 0xFF, count: 6))
        #expect(Array(packet[6..<12]) == mac.bytes)
        #expect(Array(packet.suffix(6)) == mac.bytes)
    }

    @Test func httpCheckAddsTheSchemeAndRefusesOthers() {
        #expect(HTTPCheck.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(HTTPCheck.url(from: "http://example.com/x")?.absoluteString == "http://example.com/x")
        #expect(HTTPCheck.url(from: "ftp://example.com") == nil)
        #expect(HTTPCheck.url(from: "  ") == nil)
    }
}
