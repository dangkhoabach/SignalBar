import Foundation
import GRDB
import Testing
@testable import SignalBarCore

private func ip(_ text: String) -> IPv4Address { IPv4Address(text)! }
private func mac(_ text: String) -> MACAddress { MACAddress(text)! }

@Suite struct NetworkRepositoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepo() throws -> (NetworkRepository, Int64) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = NetworkRepository(dbQueue: app.dbQueue)
        let subnet = try repo.save(NetworkSubnet(name: "Office", cidr: "10.0.20.0/24"))
        return (repo, try #require(subnet.id))
    }

    private func arp(_ address: String, _ hardware: String, hostname: String? = nil) -> HostObservation {
        HostObservation(ip: ip(address), mac: mac(hardware), source: .arpSNMP, sourceID: 1, hostname: hostname)
    }

    // MARK: Subnets

    @Test func subnetsAreValidatedAndCanonicalised() throws {
        let (repo, _) = try makeRepo()
        let saved = try repo.save(NetworkSubnet(name: " ", cidr: "10.0.30.77/24"))
        #expect(saved.cidr == "10.0.30.0/24")
        #expect(saved.name == "10.0.30.0/24")
        #expect(throws: NetworkRepositoryError.invalidCIDR) { try repo.save(NetworkSubnet(name: "x", cidr: "10.0.40.0")) }
        #expect(throws: NetworkRepositoryError.notInternal) { try repo.save(NetworkSubnet(name: "x", cidr: "8.8.8.0/24")) }
        #expect(throws: NetworkRepositoryError.notInternal) { try repo.save(NetworkSubnet(name: "x", cidr: "127.0.0.0/24")) }
        #expect(throws: NetworkRepositoryError.tooLarge) { try repo.save(NetworkSubnet(name: "x", cidr: "10.1.0.0/16")) }
        #expect(throws: NetworkRepositoryError.overlaps("Office (10.0.20.0/24)")) {
            try repo.save(NetworkSubnet(name: "x", cidr: "10.0.20.128/25"))
        }
    }

    @Test func editingASubnetDoesNotTripOverItself() throws {
        let (repo, id) = try makeRepo()
        var office = try #require(try repo.subnets().first { $0.id == id })
        office.name = "Office LAN"
        office.vlanID = 20
        try repo.save(office)
        #expect(try repo.subnets().first?.name == "Office LAN")
    }

    // MARK: Inventory

    @Test func theFirstScanIsTheStartingInventoryAndLaterArrivalsAreNew() throws {
        let (repo, subnet) = try makeRepo()
        let first = try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        #expect(first.isFirstInventory)
        #expect(first.events.map(\.kind) == [.discovered])
        #expect(first.events.first?.detail == NetworkEvent.firstInventory)

        let second = try repo.apply(
            [arp("10.0.20.5", "a4:83:e7:00:00:05"), arp("10.0.20.6", "a4:83:e7:00:00:06")],
            toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(60)
        )
        #expect(!second.isFirstInventory)
        #expect(second.events.map(\.kind) == [.discovered])
        #expect(second.events.first?.ip == "10.0.20.6")
        #expect(second.events.first?.detail == nil)
        #expect(try repo.devices().count == 2)
        // The menu bar counts only the arrival, not the starting inventory.
        #expect(try repo.summary(since: start).newRecently == 1)
    }

    @Test func anEvidentTypeFillsOnlyATypeTheUserHasNotSet() throws {
        let (repo, subnet) = try makeRepo()
        var gateway = arp("10.0.20.1", "a4:83:e7:00:00:01")
        gateway.deviceType = .router
        try repo.apply([gateway], toSubnet: subnet, isCoverageRun: false, now: start)
        var device = try #require(try repo.devices().first)
        #expect(device.deviceType == .router)

        device.deviceType = .networkSwitch
        try repo.updateUserFields(of: device)
        try repo.apply([gateway], toSubnet: subnet, isCoverageRun: false, now: start)
        #expect(try repo.devices().first?.deviceType == .networkSwitch)
    }

    @Test func aDeviceThatMovesKeepsItsIdentityAndHistory() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        let moved = try repo.apply([arp("10.0.20.9", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(60))
        #expect(moved.events.map(\.kind) == [.ipChanged])
        #expect(moved.events.first?.detail == "10.0.20.5")

        let device = try #require(try repo.devices().first)
        #expect(device.currentIP == "10.0.20.9")
        #expect(try repo.ipHistory(deviceID: device.id!).map(\.ip) == ["10.0.20.9", "10.0.20.5"])
    }

    @Test func repeatedSightingsDoNotGrowTheTables() throws {
        let (repo, subnet) = try makeRepo()
        for minute in 0..<5 {
            try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true,
                           now: start.addingTimeInterval(Double(minute) * 60))
        }
        let device = try #require(try repo.devices().first)
        let history = try repo.ipHistory(deviceID: device.id!)
        #expect(history.count == 1)
        #expect(history.first?.firstSeenAt == start)
        #expect(history.first?.lastSeenAt == start.addingTimeInterval(240))
        #expect(try repo.sightings(deviceID: device.id!).count == 1)
    }

    @Test func anAddressOnlyDeviceBecomesTheMACDeviceWhenTheMACTurnsUp() throws {
        let (repo, subnet) = try makeRepo()
        // Seen through a router first: an address and nothing else.
        try repo.apply([HostObservation(ip: ip("10.0.20.7"), mac: nil, source: .icmp)], toSubnet: subnet, isCoverageRun: true, now: start)
        var addressOnly = try #require(try repo.devices().first)
        addressOnly.displayName = "Front desk PC"
        addressOnly.isWatched = true
        try repo.updateUserFields(of: addressOnly)

        // Then a router's ARP table says which MAC holds that address.
        try repo.apply([arp("10.0.20.7", "a4:83:e7:00:00:07")], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(60))
        let devices = try repo.devices()
        #expect(devices.count == 1)
        #expect(devices.first?.mac == "a4:83:e7:00:00:07")
        #expect(devices.first?.displayName == "Front desk PC")
        #expect(devices.first?.isWatched == true)

        // And a later ping-only sighting lands on the MAC device.
        try repo.apply([HostObservation(ip: ip("10.0.20.7"), mac: nil, source: .icmp)], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(120))
        #expect(try repo.devices().count == 1)
    }

    @Test func aDeviceGoesOfflineOnlyAfterThreeMissedRunsAndComesBack() throws {
        let (repo, subnet) = try makeRepo()
        let laptop = arp("10.0.20.5", "a4:83:e7:00:00:05")
        let printer = arp("10.0.20.6", "a4:83:e7:00:00:06")
        try repo.apply([laptop, printer], toSubnet: subnet, isCoverageRun: true, now: start)

        for run in 1...2 {
            let result = try repo.apply([printer], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(Double(run) * 60))
            #expect(result.events.isEmpty)
        }
        #expect(try repo.devices().first { $0.mac == "a4:83:e7:00:00:05" }?.state == .online)

        let third = try repo.apply([printer], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(180))
        #expect(third.events.map(\.kind) == [.offline])
        // Staying gone doesn't repeat the event.
        let fourth = try repo.apply([printer], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(240))
        #expect(fourth.events.isEmpty)

        let back = try repo.apply([laptop, printer], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(300))
        #expect(back.events.map(\.kind) == [.online])
        #expect(try repo.devices().first { $0.mac == "a4:83:e7:00:00:05" }?.missedScans == 0)
    }

    @Test func aBatchThatIsNotACompleteLookCountsNoMisses() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        for run in 1...5 {
            try repo.apply([], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(Double(run) * 60))
        }
        #expect(try repo.devices().first?.state == .online)
    }

    @Test func ignoredDevicesNeverGoOffline() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        var device = try #require(try repo.devices().first)
        device.isIgnored = true
        try repo.updateUserFields(of: device)
        for run in 1...4 {
            let result = try repo.apply([], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(Double(run) * 60))
            #expect(result.events.isEmpty)
        }
    }

    @Test func aLeaseNeitherProvesPresenceNorTakesAnAddressFromALiveDevice() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)

        let lease = HostObservation(ip: ip("10.0.20.5"), mac: mac("a4:83:e7:00:00:99"), source: .dhcp, sourceID: 2,
                                    hostname: "old-phone", hostnameSource: .dhcp)
        let result = try repo.apply([lease], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(60))
        #expect(result.events.isEmpty)

        let devices = try repo.devices()
        let live = try #require(devices.first { $0.mac == "a4:83:e7:00:00:05" })
        let leased = try #require(devices.first { $0.mac == "a4:83:e7:00:00:99" })
        #expect(live.currentIP == "10.0.20.5")
        #expect(leased.state == .unknown)
        #expect(leased.lastSeenAt == nil)
        #expect(leased.hostname == "old-phone")

        // Seen for real later: that's when it's discovered.
        let seen = try repo.apply([arp("10.0.20.50", "a4:83:e7:00:00:99")], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(120))
        #expect(seen.events.contains { $0.kind == .discovered })
    }

    @Test func aBetterSourcesHostnameWins() throws {
        let (repo, subnet) = try makeRepo()
        let device = mac("a4:83:e7:00:00:05")
        try repo.apply([HostObservation(ip: ip("10.0.20.5"), mac: device, source: .arpSNMP, hostname: "host-5.lan", hostnameSource: .reverseDNS)],
                       toSubnet: subnet, isCoverageRun: false, now: start)
        try repo.apply([HostObservation(ip: ip("10.0.20.5"), mac: device, source: .dhcp, hostname: "accounting-pc", hostnameSource: .dhcp)],
                       toSubnet: subnet, isCoverageRun: false, now: start)
        try repo.apply([HostObservation(ip: ip("10.0.20.5"), mac: device, source: .arpSNMP, hostname: "host-5.lan", hostnameSource: .reverseDNS)],
                       toSubnet: subnet, isCoverageRun: false, now: start)
        #expect(try repo.devices().first?.hostname == "accounting-pc")
    }

    // MARK: Conflicts

    @Test func anAddressBouncingBetweenTwoDevicesIsAConflict() throws {
        let (repo, subnet) = try makeRepo()
        let first = arp("10.0.20.5", "a4:83:e7:00:00:05")
        let second = arp("10.0.20.5", "a4:83:e7:00:00:06")
        try repo.apply([first], toSubnet: subnet, isCoverageRun: false, now: start)

        // A DHCP server handing the address to another device: just a change of owner.
        let handover = try repo.apply([second], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(60))
        #expect(handover.events.map(\.kind) == [.discovered, .ipOwnerChanged])

        // Straight back to the first: two devices fighting over one address.
        let back = try repo.apply([first], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(120))
        #expect(back.events.map(\.kind) == [.ipOwnerChanged, .conflict])
        #expect(back.events.last?.ip == "10.0.20.5")
    }

    @Test func aSlowHandBackIsNotAConflict() throws {
        let (repo, subnet) = try makeRepo()
        let first = arp("10.0.20.5", "a4:83:e7:00:00:05")
        let second = arp("10.0.20.5", "a4:83:e7:00:00:06")
        try repo.apply([first], toSubnet: subnet, isCoverageRun: false, now: start)
        try repo.apply([second], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(60))
        let later = try repo.apply([first], toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(60 + NetworkRepository.conflictWindow + 60))
        #expect(!later.events.contains { $0.kind == .conflict })
    }

    @Test func twoMACsOnOneAddressInOneBatchIsAConflictUnlessShared() throws {
        let (repo, subnet) = try makeRepo()
        let batch = [arp("10.0.20.1", "00:00:5e:00:01:01"), arp("10.0.20.1", "a4:83:e7:00:00:01")]
        try repo.apply([arp("10.0.20.9", "a4:83:e7:00:00:09")], toSubnet: subnet, isCoverageRun: false, now: start)
        let result = try repo.apply(batch, toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(60))
        #expect(result.events.contains { $0.kind == .conflict && $0.ip == "10.0.20.1" })

        // A VRRP address: the user says it is shared on purpose.
        for var device in try repo.devices() where device.mac == "00:00:5e:00:01:01" {
            device.ignoreConflicts = true
            try repo.updateUserFields(of: device)
        }
        let again = try repo.apply(batch, toSubnet: subnet, isCoverageRun: false, now: start.addingTimeInterval(4_000))
        #expect(!again.events.contains { $0.kind == .conflict })
    }

    // MARK: Editing

    @Test func mergingMovesEverythingAndKeepsTheUsersFields() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05"), arp("10.0.20.6", "3a:00:00:00:00:06")],
                       toSubnet: subnet, isCoverageRun: false, now: start)
        let devices = try repo.devices()
        let keep = try #require(devices.first { $0.mac == "a4:83:e7:00:00:05" })
        var old = try #require(devices.first { $0.mac == "3a:00:00:00:00:06" })
        old.displayName = "Reception phone"
        try repo.updateUserFields(of: old)

        try repo.merge(old.id!, into: keep.id!, now: start.addingTimeInterval(10))
        let after = try repo.devices()
        #expect(after.count == 1)
        #expect(after.first?.displayName == "Reception phone")
        #expect(try repo.ipHistory(deviceID: keep.id!).count == 2)
        #expect(try repo.events(deviceID: keep.id!).contains { $0.kind == .merged })
    }

    @Test func userFieldsAreSavedWithoutUndoingAScan() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        var stale = try #require(try repo.devices().first)
        try repo.apply([arp("10.0.20.8", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start.addingTimeInterval(60))

        stale.displayName = "  "
        stale.notes = "Under the desk"
        stale.deviceType = .computer
        try repo.updateUserFields(of: stale)
        let saved = try #require(try repo.devices().first)
        #expect(saved.currentIP == "10.0.20.8")
        #expect(saved.displayName == nil)
        #expect(saved.notes == "Under the desk")
        #expect(saved.deviceType == .computer)
    }

    @Test func switchLocationsFillInVLANAndPort() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: false, now: start)
        try repo.updateSwitchLocations(vlans: [mac("a4:83:e7:00:00:05"): 20], ports: [mac("a4:83:e7:00:00:05"): "Gi1/0/7"], switchName: "core-sw")
        let device = try #require(try repo.devices().first)
        #expect(device.vlanID == 20)
        #expect(device.switchPort == "Gi1/0/7")
        #expect(device.switchName == "core-sw")
    }

    // MARK: Sources, ports, housekeeping

    @Test func aSourceAlertsOnTheThirdFailureAndOnRecovery() throws {
        let (repo, _) = try makeRepo()
        let source = try repo.save(NetworkSource(kind: .snmp, name: "Core switch", host: "10.0.0.2"))
        let id = try #require(source.id)
        #expect(try repo.recordPoll(sourceID: id, error: "No answer", now: start) == nil)
        #expect(try repo.recordPoll(sourceID: id, error: "No answer", now: start) == nil)
        #expect(try repo.recordPoll(sourceID: id, error: "No answer", now: start)?.kind == .sourceFailed)
        #expect(try repo.recordPoll(sourceID: id, error: "No answer", now: start) == nil)
        let recovered = try repo.recordPoll(sourceID: id, error: nil, system: SNMPSystemInfo(name: "core-sw", description: "OS", uptimeTicks: 1), now: start)
        #expect(recovered?.kind == .sourceRecovered)
        #expect(try repo.source(id: id)?.sysName == "core-sw")
        #expect(try repo.source(id: id)?.consecutiveFailures == 0)
    }

    @Test func interfaceRatesComeFromConsecutiveReadingsAndSkipResets() throws {
        let (repo, _) = try makeRepo()
        let id = try #require(try repo.save(NetworkSource(kind: .snmp, name: "sw", host: "10.0.0.2")).id)
        func reading(_ octets: UInt64) -> SNMPInterfaceReading {
            SNMPInterfaceReading(index: 1, name: "Gi0/1", operStatus: 1, speedMbps: 1_000, inOctets: octets, outOctets: octets / 2, hasHighCapacityCounters: true)
        }
        try repo.recordInterfaces([reading(1_000_000)], sourceID: id, now: start)
        #expect(try repo.interfaces(sourceID: id).first?.inBps == nil)

        try repo.recordInterfaces([reading(1_000_000 + 125_000 * 60)], sourceID: id, now: start.addingTimeInterval(60))
        let second = try #require(try repo.interfaces(sourceID: id).first)
        #expect(second.inBps == 1_000_000)
        #expect(try repo.samples(sourceID: id, ifIndex: 1, since: start).count == 1)

        // The device restarted: counters went back to near zero.
        try repo.recordInterfaces([reading(500)], sourceID: id, now: start.addingTimeInterval(120))
        #expect(try repo.interfaces(sourceID: id).first?.inBps == nil)
        #expect(NetworkRepository.rate(from: Int64(bitPattern: UInt64.max - 10), to: Int64(bitPattern: UInt64.max), seconds: 1) == 80)
    }

    @Test func portScansReportOnlyChangesAfterTheFirst() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: false, now: start)
        let id = try #require(try repo.devices().first?.id)
        let baseline = try repo.recordPortScan(deviceID: id, results: [(22, .open, 1), (80, .closed, 1), (443, .filtered, nil)], now: start)
        #expect(baseline.isEmpty)
        let changed = try repo.recordPortScan(deviceID: id, results: [(22, .closed, 1), (80, .open, 1), (443, .filtered, nil)], now: start)
        #expect(Set(changed.map { "\($0.kind.rawValue):\($0.detail ?? "")" }) == ["port_closed:22", "port_opened:80"])
        #expect(try repo.portResults(deviceID: id).map(\.port) == [22, 80, 443])
    }

    @Test func alertsHaveACooldownPerKind() throws {
        let (repo, subnet) = try makeRepo()
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: false, now: start)
        let id = try #require(try repo.devices().first?.id)
        #expect(try repo.claimAlert(deviceID: id, kind: .conflict, now: start))
        #expect(try !repo.claimAlert(deviceID: id, kind: .conflict, now: start.addingTimeInterval(600)))
        #expect(try repo.claimAlert(deviceID: id, kind: .conflict, now: start.addingTimeInterval(3_700)))
    }

    @Test func housekeepingAndDeletingAllNetworkDataLeaveTheRestAlone() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = NetworkRepository(dbQueue: app.dbQueue)
        let targets = TargetRepository(dbQueue: app.dbQueue)
        _ = try targets.add(NewTargetInput(name: "Example", url: "https://example.com"))
        let subnet = try #require(try repo.save(NetworkSubnet(name: "Office", cidr: "10.0.20.0/24")).id)
        try repo.apply([arp("10.0.20.5", "a4:83:e7:00:00:05")], toSubnet: subnet, isCoverageRun: true, now: start)
        let old = try repo.beginScan(subnetID: subnet, trigger: "manual", now: start)
        try repo.finishScan(old, status: .completed, outcome: nil, now: start)

        try repo.cleanUp(now: start.addingTimeInterval(Double(NetworkRepository.scanRetentionDays + 1) * 86_400))
        #expect(try app.dbQueue.read { try NetworkScan.fetchCount($0) } == 0)
        #expect(try repo.devices().count == 1)

        let source = try repo.save(NetworkSource(kind: .snmp, name: "sw", host: "10.0.0.2", keychainRef: "ref-1"))
        #expect(try repo.deleteAll() == [source.keychainRef])
        #expect(try repo.devices().isEmpty)
        #expect(try repo.subnets().isEmpty)
        #expect(try targets.list().count == 1)
    }

    @Test func abandonedScansAreClosedOnLaunch() throws {
        let (repo, subnet) = try makeRepo()
        _ = try repo.beginScan(subnetID: subnet, trigger: "scheduled", now: start)
        try repo.closeAbandonedScans(now: start)
        #expect(try repo.dbQueue.read { try NetworkScan.fetchOne($0)?.status } == .cancelled)
    }
}
