import Foundation
import GRDB
import Testing
@testable import SignalBarCore

@Suite struct LocalConnectionTests {
    private let wifiService = "SERVICE-WIFI"
    private let vpnService = "SERVICE-VPN"

    private func wifiLink() -> LinkAddresses {
        var link = LinkAddresses(name: "en0")
        link.ipv4 = [(IPv4Address("10.0.20.15")!, 24)]
        link.ipv6 = [("fe80::1c:2d3e", 64), ("2001:db8::10", 64), ("2001:db8::aaaa", 64), ("2001:db8::bbbb", 64)]
        link.mac = MACAddress("1a:00:00:00:00:01")
        link.mtu = 1500
        return link
    }

    private func state(dnsTyped: [String]? = nil, globalDNS: [String] = ["10.0.20.1"]) -> [String: [String: Any]] {
        var state: [String: [String: Any]] = [
            "State:/Network/Global/IPv4": ["PrimaryInterface": "en0", "PrimaryService": wifiService, "Router": "10.0.20.1"],
            "State:/Network/Global/IPv6": ["PrimaryInterface": "en0", "Router": "fe80::1"],
            "State:/Network/Global/DNS": ["ServerAddresses": globalDNS, "SearchDomains": ["lab.example"]],
            "State:/Network/Service/\(wifiService)/IPv4": ["InterfaceName": "en0", "Router": "10.0.20.1"],
            "State:/Network/Service/\(wifiService)/DNS": ["ServerAddresses": ["10.0.20.1", "192.0.2.53"]],
            "State:/Network/Service/\(wifiService)/DHCP": [
                "Option_54": Data([10, 0, 20, 1]),
                "Option_6": Data([10, 0, 20, 1, 192, 0, 2, 53]),
                "Option_15": Data("lab.example".utf8 + [0]),
                "LeaseStartTime": Date(timeIntervalSince1970: 1_000),
                "LeaseExpirationTime": Date(timeIntervalSince1970: 87_400),
            ],
            "State:/Network/Interface/en0/IPv6": [
                "Addresses": ["fe80::1c:2d3e", "2001:db8::10", "2001:db8::aaaa", "2001:db8::bbbb"],
                // stable (autoconf + secured), current privacy address, deprecated privacy address.
                "Flags": [1024, 1088, 192, 208],
            ],
            "Setup:/Network/Service/\(wifiService)": ["UserDefinedName": "Wi-Fi"],
        ]
        if let dnsTyped { state["Setup:/Network/Service/\(wifiService)/DNS"] = ["ServerAddresses": dnsTyped] }
        return state
    }

    @Test func thePrimaryInterfaceComesWithItsLeaseAndAddresses() throws {
        let connection = SystemNetworkReader.build(links: [wifiLink()], state: state(), proxies: [:])
        let primary = try #require(connection.primary)
        #expect(primary.serviceName == "Wi-Fi")
        #expect(primary.ipv4 == IPv4Address("10.0.20.15"))
        #expect(primary.subnetMask == IPv4Address("255.255.255.0"))
        #expect(primary.router == "10.0.20.1")
        #expect(primary.ipv6Router == "fe80::1")
        // The deprecated privacy address is left out.
        #expect(primary.ipv6.map(\.kind) == [.linkLocal, .stable, .temporary])
        #expect(primary.dhcp == DHCPLeaseInfo(server: "10.0.20.1", leaseStart: Date(timeIntervalSince1970: 1_000),
                                              leaseEnd: Date(timeIntervalSince1970: 87_400), domainName: "lab.example",
                                              offeredDNS: ["10.0.20.1", "192.0.2.53"]))
        #expect(connection.tunnels.isEmpty)
        #expect(!connection.vpnCarriesAllTraffic)
    }

    @Test func typedDNSServersShowWhatTheNetworkOffered() {
        let typed = SystemNetworkReader.build(links: [wifiLink()], state: state(dnsTyped: ["9.9.9.9"], globalDNS: ["9.9.9.9"]), proxies: [:]).dns
        #expect(typed.source == .manual)
        #expect(typed.servers == ["9.9.9.9"])
        #expect(typed.offeredByNetwork == ["10.0.20.1", "192.0.2.53"])

        let automatic = SystemNetworkReader.build(links: [wifiLink()], state: state(), proxies: [:]).dns
        #expect(automatic.source == .network)
        #expect(automatic.offeredByNetwork.isEmpty)
        #expect(automatic.searchDomains == ["lab.example"])
    }

    @Test func aTunnelWithAnAddressIsAVPNAndOnesWithoutAreApples() {
        var vpn = LinkAddresses(name: "utun4", isPointToPoint: true)
        vpn.ipv4 = [(IPv4Address("100.101.102.103")!, 32)]
        var system = LinkAddresses(name: "utun0", isPointToPoint: true)
        system.ipv6 = [("fe80::abcd", 64)]

        var values = state(globalDNS: ["100.100.100.100"])
        values["State:/Network/Global/IPv4"]?["PrimaryInterface"] = "utun4"
        values["State:/Network/Service/\(vpnService)/IPv4"] = ["InterfaceName": "utun4"]
        values["State:/Network/Service/\(vpnService)/DNS"] = ["ServerAddresses": ["100.100.100.100"]]
        values["State:/Network/Service/SPLIT/DNS"] = ["ServerAddresses": ["10.9.0.53"], "SupplementalMatchDomains": ["corp.example"]]
        values["Setup:/Network/Service/\(vpnService)"] = ["UserDefinedName": "Tailscale"]

        let connection = SystemNetworkReader.build(links: [wifiLink(), vpn, system], state: values, proxies: [:])
        #expect(connection.tunnels == [VPNTunnel(name: "utun4", serviceName: "Tailscale", addresses: ["100.101.102.103"])])
        #expect(connection.tunnels.first?.looksLikeTailscale == true)
        #expect(connection.vpnCarriesAllTraffic)
        #expect(connection.dns.source == .vpn)
        #expect(connection.dns.scoped == [DNSSettings.Scoped(domains: ["corp.example"], servers: ["10.9.0.53"])])
        // The tunnel runs over en0, which is still what the Mac is connected with.
        #expect(connection.primary?.name == "en0")
        #expect(connection.primary?.router == "10.0.20.1")
        #expect(connection.others.isEmpty)
    }

    @Test func onlyProxiesThatAreSwitchedOnCount() {
        let proxies = SystemNetworkReader.proxySettings([
            "HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 3128,
            "HTTPSEnable": 0, "HTTPSProxy": "unused.example", "HTTPSPort": 443,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://wpad.example/proxy.pac",
            "ExceptionsList": ["*.local"],
        ])
        #expect(proxies.http == "proxy.example:3128")
        #expect(proxies.https == nil)
        #expect(proxies.autoConfigURL == "http://wpad.example/proxy.pac")
        #expect(proxies.isActive)
        #expect(!SystemNetworkReader.proxySettings(["ExceptionsList": ["*.local"]]).isActive)
    }

    @Test func countersThatWrappedStillGiveTheRate() throws {
        let earlier = InterfaceCounters(bytesIn: UInt32.max - 999, bytesOut: 0, readAt: Date(timeIntervalSince1970: 0))
        let later = InterfaceCounters(bytesIn: 1_000, bytesOut: 250, readAt: Date(timeIntervalSince1970: 2))
        let rates = try #require(later.rates(since: earlier))
        #expect(rates.inBitsPerSecond == 2_000 * 8 / 2)
        #expect(rates.outBitsPerSecond == 1_000)
    }

    @Test func wifiQualityFollowsSignalToNoise() {
        func status(rssi: Int) -> WiFiStatus {
            WiFiStatus(interfaceName: "en0", rssi: rssi, noise: -95, transmitRateMbps: 0)
        }
        #expect(status(rssi: -50).quality == .excellent)
        #expect(status(rssi: -65).quality == .good)
        #expect(status(rssi: -75).quality == .fair)
        #expect(status(rssi: -85).quality == .poor)
    }
}

@Suite struct PublicAddressTests {
    @Test func theTraceGivesTheAddressOfTheFamilyAsked() throws {
        let trace = "fl=1\nh=1.1.1.1\nip=203.0.113.7\nts=1\ncolo=SGN\nloc=VN\nwarp=off\n"
        let address = try #require(PublicAddressLookup.parseTrace(trace, family: .ipv4))
        #expect(address == PublicAddress(family: .ipv4, ip: "203.0.113.7", country: "VN", colo: "SGN"))
        #expect(PublicAddressLookup.parseTrace(trace, family: .ipv6) == nil)
        #expect(PublicAddressLookup.parseTrace("ip=2001:db8::1\nloc=XX\nwarp=on", family: .ipv6)
            == PublicAddress(family: .ipv6, ip: "2001:db8::1", warp: true))
        #expect(PublicAddressLookup.parseTrace("<html>blocked</html>", family: .ipv4) == nil)
    }

    @Test func ripeStatNamesTheNetwork() throws {
        let json = #"{"data":{"asns":[{"asn":64500,"holder":"EXAMPLE-AS-VN - Example Telecom"}],"resource":"203.0.113.0/24"}}"#
        let network = try #require(PublicAddressLookup.parseRIPEOverview(Data(json.utf8)))
        #expect(network.asn == 64500)
        #expect(network.holder == "Example Telecom")
        #expect(PublicAddressLookup.parseRIPEOverview(Data(#"{"data":{"asns":[]}}"#.utf8)) == nil)
        #expect(PublicAddressLookup.cleanHolder("NOSEPARATOR") == "NOSEPARATOR")
    }

    @Test func aDNSAnswerIsReadForBothFamilies() {
        let query = DNSMessage.query("myip.opendns.com", type: 1, id: 0x1234)
        #expect(Array(query.prefix(4)) == [0x12, 0x34, 0x01, 0x00])
        #expect(Array(query.suffix(4)) == [0, 1, 0, 1])

        // The query echoed back as the question, then an A and an AAAA
        // answer whose names point back at it.
        var reply = query
        reply[2] = 0x81
        reply[3] = 0x80
        reply[7] = 2
        reply += [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 7]
        reply += [0xC0, 12, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16, 0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1]
        #expect(DNSMessage.addresses(in: reply) == ["203.0.113.7", "2001:db8::1"])
        #expect(DNSMessage.addresses(in: Array(reply.prefix(20))) == [])
    }

    @Test func theHopAfterTheRouterTellsHowManyNATsThereAre() {
        let router = IPv4Address("192.168.1.1")
        #expect(NATLayout.classify(hops: [router, IPv4Address("203.0.113.1")]) == .single)
        #expect(NATLayout.classify(hops: [router, IPv4Address("192.168.0.1")]) == .double)
        #expect(NATLayout.classify(hops: [router, IPv4Address("100.72.0.1")]) == .carrierGrade)
        #expect(NATLayout.classify(hops: [router, nil, IPv4Address("203.0.113.1")]) == .unknown)
        #expect(NATLayout.classify(hops: [router]) == .unknown)
    }

    @Test func onlyOurOwnExpiredEchoCountsAsAHop() {
        let echo = HostSweep.echoRequest(identifier: 0xBEEF, sequence: 2)
        let innerIP: [UInt8] = [0x45] + Array(repeating: 0, count: 19)
        let outerIP: [UInt8] = [0x45] + Array(repeating: 0, count: 19)
        let exceeded = outerIP + [11, 0, 0, 0, 0, 0, 0, 0] + innerIP + echo
        #expect(EchoProbe.isTimeExceeded(exceeded[...], identifier: 0xBEEF, sequence: 2))
        #expect(!EchoProbe.isTimeExceeded(exceeded[...], identifier: 0xBEEF, sequence: 3))
        #expect(!EchoProbe.isTimeExceeded(exceeded[...], identifier: 0xCAFE, sequence: 2))
        var unreachable = exceeded
        unreachable[20] = 3
        #expect(!EchoProbe.isTimeExceeded(unreachable[...], identifier: 0xBEEF, sequence: 2))
    }
}

@Suite struct ConnectionRepositoryTests {
    @Test func aNewAddressIsReportedOnlyWhenItReplacesAnother() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = ConnectionRepository(dbQueue: app.dbQueue)
        let first = PublicAddress(family: .ipv4, ip: "203.0.113.7", country: "VN")
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(try repo.record(first, at: start) == nil)
        // Same address later: confirmed, and what was missing gets filled in.
        var again = first
        again.asn = 64500
        #expect(try repo.record(again, at: start.addingTimeInterval(600)) == nil)
        // The other family is tracked on its own.
        #expect(try repo.record(PublicAddress(family: .ipv6, ip: "2001:db8::1"), at: start.addingTimeInterval(700)) == nil)

        let previous = try #require(try repo.record(PublicAddress(family: .ipv4, ip: "198.51.100.9"), at: start.addingTimeInterval(1_200)))
        #expect(previous.ip == "203.0.113.7")
        #expect(previous.asn == 64500)
        #expect(previous.lastSeenAt == start.addingTimeInterval(600))

        #expect(try repo.history().map(\.ip) == ["198.51.100.9", "2001:db8::1", "203.0.113.7"])
        try repo.clearHistory()
        #expect(try repo.history().isEmpty)
    }

    @Test func theChangeAlertNamesBothAddresses() {
        let text = EnglishAlertText().text(for: .publicIPChanged(old: "203.0.113.7", new: "198.51.100.9", holder: "Example Telecom"))
        #expect(text.title == "Public IP changed to 198.51.100.9")
        #expect(text.body == "Was 203.0.113.7 · Example Telecom")
    }
}
