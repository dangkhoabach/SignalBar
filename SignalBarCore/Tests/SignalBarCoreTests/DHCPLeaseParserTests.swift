import Foundation
import Testing
@testable import SignalBarCore

@Suite struct DHCPLeaseParserTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsDnsmasqLeases() {
        let text = """
            1800003600 a4:83:e7:01:02:03 192.168.1.20 office-laptop 01:a4:83:e7:01:02:03
            1799990000 00:11:22:33:44:55 192.168.1.21 * *
            0 00:11:22:33:44:66 192.168.1.22 printer *
            garbage line
            """
        let leases = DHCPLeaseParser.parse(text, format: .dnsmasq, now: now)
        #expect(leases.map(\.ip.description) == ["192.168.1.20", "192.168.1.21", "192.168.1.22"])
        #expect(leases[0].hostname == "office-laptop")
        #expect(leases[0].isActive)
        #expect(leases[1].hostname == nil)
        #expect(!leases[1].isActive)
        #expect(leases[2].endsAt == nil && leases[2].isActive)
    }

    @Test func readsISCLeasesWithTheLastBlockWinning() {
        let text = """
            # The format of this file is documented in the dhcpd.leases(5) manual page.
            lease 10.0.20.15 {
              starts 4 2027/01/14 10:00:00;
              ends 4 2027/01/14 22:00:00;
              binding state free;
              hardware ethernet a4:83:e7:01:02:03;
            }
            lease 10.0.20.15 {
              starts 5 2027/01/15 08:00:00;
              ends 5 2027/01/15 20:00:00;
              binding state active;
              hardware ethernet a4:83:e7:01:02:03;
              client-hostname "meeting-room-tv";
            }
            lease 10.0.20.16 {
              ends never;
              binding state active;
              hardware ethernet 00:11:22:33:44:55;
            }
            """
        let leases = DHCPLeaseParser.parse(text, format: .iscDhcpd, now: now)
        #expect(leases.count == 2)
        #expect(leases[0].hostname == "meeting-room-tv")
        #expect(leases[0].isActive)
        #expect(leases[0].endsAt != nil)
        #expect(leases[1].endsAt == nil && leases[1].isActive)
    }

    @Test func readsKeaMemfiles() {
        let text = """
            address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context
            10.0.30.5,a4:83:e7:01:02:03,,3600,1800003600,1,0,0,camera-1.,0,
            10.0.30.6,00:11:22:33:44:55,,3600,1800003600,1,0,0,,1,
            10.0.30.7,00:11:22:33:44:66,,3600,1799000000,1,0,0,old,0,
            """
        let leases = DHCPLeaseParser.parse(text, format: .kea, now: now)
        #expect(leases.map(\.isActive) == [true, false, false])
        #expect(leases[0].hostname == "camera-1")
        #expect(leases[1].hostname == nil)
    }

    @Test func readsCSVWithOrWithoutAHeader() {
        let withHeader = """
            Name;MAC Address;IP Address
            core-switch;00-11-22-33-44-55;10.0.0.2
            """
        let leases = DHCPLeaseParser.parse(withHeader, format: .csv, now: now)
        #expect(leases.count == 1)
        #expect(leases[0].ip.description == "10.0.0.2")
        #expect(leases[0].mac.description == "00:11:22:33:44:55")
        #expect(leases[0].hostname == "core-switch")
        #expect(leases[0].isReserved)

        let bare = "10.0.0.3,00:11:22:33:44:66,nas\n10.0.0.4,not-a-mac,x\n"
        #expect(DHCPLeaseParser.parse(bare, format: .csv, now: now).map(\.hostname) == ["nas"])
    }

    @Test func readsMikroTikJSON() throws {
        let json = """
            [{".id":"*1","address":"10.0.20.40","mac-address":"A4:83:E7:01:02:03","host-name":"phone","status":"bound","dynamic":"true","expires-after":"9m30s"},
             {".id":"*2","address":"10.0.20.2","mac-address":"00:11:22:33:44:55","status":"waiting","dynamic":"false"}]
            """
        let leases = DHCPLeaseParser.mikroTik(Data(json.utf8), now: now)
        #expect(leases.count == 2)
        #expect(leases[0].isActive && !leases[0].isReserved)
        #expect(leases[0].endsAt == now.addingTimeInterval(570))
        #expect(!leases[1].isActive && leases[1].isReserved)
    }

    @Test func readsRouterOSDurations() {
        #expect(DHCPLeaseParser.routerOSDuration("1w2d3h4m5s") == TimeInterval(604_800 + 172_800 + 10_800 + 240 + 5))
        #expect(DHCPLeaseParser.routerOSDuration("45s") == 45)
        #expect(DHCPLeaseParser.routerOSDuration("10") == nil)
        #expect(DHCPLeaseParser.routerOSDuration("") == nil)
        #expect(DHCPLeaseParser.routerOSDuration("3x") == nil)
    }
}
