import Darwin
import Foundation
import Testing
@testable import SignalBarCore

@Suite struct NetworkAddressTests {
    @Test func parsesDottedQuadsAndRejectsEverythingElse() {
        #expect(IPv4Address("192.168.1.10")?.value == 0xC0A8_010A)
        #expect(IPv4Address("0.0.0.0")?.value == 0)
        #expect(IPv4Address("255.255.255.255")?.value == UInt32.max)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "a.b.c.d", "1..2.3", " 1.2.3.4", "1.2.3.4/24", "1234.1.1.1"] {
            #expect(IPv4Address(bad) == nil, "\(bad)")
        }
        #expect(IPv4Address(0xC0A8_010A).description == "192.168.1.10")
    }

    @Test func cidrIsCanonicalised() throws {
        let network = try #require(IPv4CIDR("192.168.1.77/24"))
        #expect(network.description == "192.168.1.0/24")
        #expect(network == IPv4CIDR("192.168.1.0/24"))
        #expect(IPv4CIDR("10.1.2.3/8")?.description == "10.0.0.0/8")
    }

    @Test func rejectsMalformedCIDR() {
        for bad in ["192.168.1.0", "192.168.1.0/", "192.168.1.0/33", "192.168.1.0/-1", "/24", "192.168.1.0/24/1", "192.168.1.0/2a"] {
            #expect(IPv4CIDR(bad) == nil, "\(bad)")
        }
    }

    @Test func hostsLeaveOutNetworkAndBroadcastExceptOnPointToPointPrefixes() throws {
        let slash24 = try #require(IPv4CIDR("192.168.1.0/24"))
        #expect(slash24.hosts.count == 254)
        #expect(slash24.hosts.first?.description == "192.168.1.1")
        #expect(slash24.hosts.last?.description == "192.168.1.254")
        #expect(IPv4CIDR("10.0.0.0/30")?.hosts.map(\.description) == ["10.0.0.1", "10.0.0.2"])
        #expect(IPv4CIDR("10.0.0.0/31")?.hosts.map(\.description) == ["10.0.0.0", "10.0.0.1"])
        #expect(IPv4CIDR("10.0.0.5/32")?.hosts.map(\.description) == ["10.0.0.5"])
        #expect(IPv4CIDR("10.0.0.0/22")?.hosts.count == 1_022)
        #expect(IPv4CIDR("10.0.0.0/22")?.broadcast.description == "10.0.3.255")
    }

    @Test func containsAndOverlaps() throws {
        let office = try #require(IPv4CIDR("10.0.0.0/22"))
        #expect(office.contains(IPv4Address("10.0.3.200")!))
        #expect(!office.contains(IPv4Address("10.0.4.1")!))
        #expect(office.overlaps(IPv4CIDR("10.0.2.0/24")!))
        #expect(IPv4CIDR("10.0.2.0/24")!.overlaps(office))
        #expect(!office.overlaps(IPv4CIDR("10.0.4.0/24")!))
    }

    @Test func buildsFromAnInterfaceNetmask() {
        let address = IPv4Address("192.168.20.15")!
        #expect(IPv4CIDR(address: address, netmask: IPv4Address("255.255.255.0")!)?.description == "192.168.20.0/24")
        #expect(IPv4CIDR(address: address, netmask: IPv4Address("255.255.252.0")!)?.description == "192.168.20.0/22")
        #expect(IPv4CIDR(address: address, netmask: IPv4Address("255.0.255.0")!) == nil)
    }

    @Test func onlyPrivateRangesCountAsInternal() {
        #expect(IPv4CIDR("192.168.0.0/16")!.isInternal)
        #expect(IPv4CIDR("10.20.0.0/24")!.isInternal)
        #expect(IPv4CIDR("172.16.5.0/24")!.isInternal)
        #expect(!IPv4CIDR("8.8.8.0/24")!.isInternal)
        // Straddles the edge of 10/8: half of it is public.
        #expect(!IPv4CIDR("10.0.0.0/7")!.isInternal)
    }

    @Test func parsesEveryMACNotation() {
        let expected = "aa:bb:cc:0d:0e:0f"
        for text in ["aa:bb:cc:0d:0e:0f", "AA-BB-CC-0D-0E-0F", "aabb.cc0d.0e0f", "aabbcc0d0e0f", "aa:bb:cc:d:e:f"] {
            #expect(MACAddress(text)?.description == expected, "\(text)")
        }
        for bad in ["", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "gg:bb:cc:dd:ee:ff", "aaa:bb:cc:dd:ee:f", "(incomplete)"] {
            #expect(MACAddress(bad) == nil, "\(bad)")
        }
    }

    @Test func recognisesPrivateAndGroupAddresses() {
        #expect(MACAddress("3a:11:22:33:44:55")!.isLocallyAdministered)
        #expect(!MACAddress("38:11:22:33:44:55")!.isLocallyAdministered)
        #expect(MACAddress("ff:ff:ff:ff:ff:ff")!.isGroup)
        #expect(MACAddress("01:00:5e:00:00:fb")!.isGroup)
        #expect(MACAddress("00:00:00:00:00:00")!.isZero)
        #expect(MACAddress("a4:83:e7:01:02:03")!.oui == 0xA483E7)
    }

    @Test func vendorLookupSkipsPrivateAddresses() {
        let table = OUIDatabase(tsv: "A483E7\tExample Corp\n001122\tOther Ltd\nbroken line\n")
        #expect(table.vendor(for: MACAddress("a4:83:e7:01:02:03")!) == "Example Corp")
        #expect(table.vendor(for: MACAddress("00:11:22:01:02:03")!) == "Other Ltd")
        #expect(table.vendor(for: MACAddress("02:11:22:01:02:03")!) == nil)
        #expect(table.vendor(for: MACAddress("cc:cc:cc:01:02:03")!) == nil)
    }
}

@Suite struct NetworkProbeTests {
    @Test func echoRequestCarriesAValidChecksum() {
        let packet = HostSweep.echoRequest(identifier: 0x1234, sequence: 7)
        #expect(packet[0] == 8)
        #expect(packet[4] == 0x12 && packet[5] == 0x34)
        // A correct checksum makes the whole packet sum to zero.
        #expect(HostSweep.internetChecksum(packet) == 0)
    }

    @Test func recognisesEchoRepliesWithOrWithoutTheIPHeader() {
        let reply: [UInt8] = [0, 0, 0, 0, 0x12, 0x34, 0, 7] + Array("SignalBr".utf8)
        let ipHeader: [UInt8] = [0x45, 0, 0, 36, 0, 0, 0, 0, 64, 1, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2]
        #expect(HostSweep.isEchoReply(reply[...], identifier: 0x1234))
        #expect(HostSweep.isEchoReply((ipHeader + reply)[...], identifier: 0x1234))
        #expect(!HostSweep.isEchoReply(reply[...], identifier: 0x9999))
        var request = reply
        request[0] = 8
        #expect(!HostSweep.isEchoReply(request[...], identifier: 0x1234))
        #expect(!HostSweep.isEchoReply([0, 0, 0][...], identifier: 0x1234))
    }

    @Test func aDeniedSweepIsRecognised() {
        var denied = SweepResult()
        var downHosts = SweepResult()
        let hosts = (1...10).map { IPv4Address(0x0A00_0000 + UInt32($0)) }
        for host in hosts {
            denied.firstPassErrors[host] = EHOSTUNREACH
            downHosts.firstPassErrors[host] = EHOSTUNREACH
        }
        #expect(SubnetScanner.looksDenied(denied, hostCount: hosts.count))
        // Devices marked down by an earlier scan are refused too, but the
        // router answers: that's not a denial.
        downHosts.firstPassErrors[hosts[0]] = nil
        #expect(!SubnetScanner.looksDenied(downHosts, hostCount: hosts.count))
        var answered = denied
        answered.echoReplies[hosts[0]] = 1
        #expect(!SubnetScanner.looksDenied(answered, hostCount: hosts.count))
    }

    @Test func resetsCountAsPresenceUnlessAFirewallSendsThemForEveryAddress() {
        let hosts = (1...20).map { IPv4Address(0x0A00_0000 + UInt32($0)) }
        // Two real hosts: one with an open port, one only resetting.
        let few = [
            TCPProbeResult(ip: hosts[0], port: 22, state: .open, latencyMs: 2),
            TCPProbeResult(ip: hosts[1], port: 80, state: .closed, latencyMs: 3),
        ] + hosts.dropFirst(2).map { TCPProbeResult(ip: $0, port: 22, state: .filtered, latencyMs: nil) }
        #expect(Set(SubnetScanner.hostsPresent(from: few, probedHostCount: hosts.count).keys) == [hosts[0], hosts[1]])

        // Every address resets: a firewall answering for empty addresses.
        let rejecting = hosts.map { TCPProbeResult(ip: $0, port: 22, state: .closed, latencyMs: 1) }
            + [TCPProbeResult(ip: hosts[5], port: 443, state: .open, latencyMs: 1)]
        #expect(Set(SubnetScanner.hostsPresent(from: rejecting, probedHostCount: hosts.count).keys) == [hosts[5]])
    }

    @Test func multicastDNSQueryAndAnswerRoundTrip() throws {
        let address = IPv4Address("192.168.1.20")!
        let query = DNSMessage.ptrQuery(for: [address])
        #expect(query[5] == 1)
        #expect(DNSMessage.reverseName(address) == "20.1.168.192.in-addr.arpa")

        // An answer whose target name points back into the question's name.
        var answer: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        let ownerOffset = answer.count
        for label in ["20", "1", "168", "192", "in-addr", "arpa"] {
            answer.append(UInt8(label.utf8.count))
            answer += Array(label.utf8)
        }
        answer.append(0)
        answer += [0, 12, 0, 1, 0, 0, 0, 120]
        let target: [UInt8] = [12] + Array("Office-Print".utf8) + [5] + Array("local".utf8) + [0]
        answer += [0, UInt8(target.count)] + target
        #expect(ownerOffset == 12)
        let parsed = DNSMessage.ptrAnswers(in: answer)
        #expect(parsed.count == 1)
        #expect(parsed.first?.0 == address)
        #expect(parsed.first.map { NameLookup.clean($0.1) } == "Office-Print")

        // A compression pointer that loops on itself is cut off, not followed forever.
        #expect(DNSMessage.readName([0xC0, 0x00], at: 0) == nil)
    }

    @Test func cleansNames() {
        #expect(NameLookup.clean("printer.local.") == "printer")
        #expect(NameLookup.clean("nas.home.arpa.") == "nas.home.arpa")
        #expect(NameLookup.clean("192.168.1.5") == nil)
        #expect(NameLookup.clean(".") == nil)
    }
}
