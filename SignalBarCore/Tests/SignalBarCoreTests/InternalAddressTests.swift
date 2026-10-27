import Foundation
import Testing
@testable import SignalBarCore

@Suite struct InternalAddressTests {
    /// The address that motivates the whole check: cloud metadata, reachable
    /// from inside a VM and holding its credentials.
    @Test func treatsTheCloudMetadataAddressAsInternal() {
        #expect(InternalAddress.isInternal(ip: "169.254.169.254"))
    }

    @Test func recognisesLoopbackAndPrivateRanges() {
        #expect(InternalAddress.isInternal(ip: "127.0.0.1"))
        #expect(InternalAddress.isInternal(ip: "10.1.2.3"))
        #expect(InternalAddress.isInternal(ip: "192.168.1.50"))
        #expect(InternalAddress.isInternal(ip: "172.16.0.1"))
        #expect(InternalAddress.isInternal(ip: "172.31.255.254"))
        #expect(InternalAddress.isInternal(ip: "100.64.0.1"))
        #expect(InternalAddress.isInternal(ip: "0.0.0.0"))
    }

    /// The boundaries of the ranges that aren't whole octets — getting the
    /// mask wrong here would either wave private addresses through or block
    /// public ones.
    @Test func getsTheEdgesOfThePartialRangesRight() {
        #expect(!InternalAddress.isInternal(ip: "172.15.255.255"))
        #expect(!InternalAddress.isInternal(ip: "172.32.0.0"))
        #expect(!InternalAddress.isInternal(ip: "100.63.255.255"))
        #expect(!InternalAddress.isInternal(ip: "100.128.0.0"))
        #expect(!InternalAddress.isInternal(ip: "169.253.0.1"))
    }

    @Test func leavesOrdinaryPublicAddressesAlone() {
        #expect(!InternalAddress.isInternal(ip: "8.8.8.8"))
        #expect(!InternalAddress.isInternal(ip: "1.1.1.1"))
        #expect(!InternalAddress.isInternal(ip: "93.184.216.34"))
        #expect(!InternalAddress.isInternal(ip: "172.217.16.142"))
    }

    @Test func recognisesInternalIPv6() {
        #expect(InternalAddress.isInternal(ip: "::1"))
        #expect(InternalAddress.isInternal(ip: "::"))
        #expect(InternalAddress.isInternal(ip: "fe80::1"))
        #expect(InternalAddress.isInternal(ip: "fd00::1"))
        #expect(!InternalAddress.isInternal(ip: "2606:4700:4700::1111"))
    }

    /// An IPv4 address wrapped in IPv6 notation is the same address, and must
    /// not slip past by changing how it's spelled.
    @Test func seesThroughIPv4MappedIPv6() {
        #expect(InternalAddress.isInternal(ip: "::ffff:127.0.0.1"))
        #expect(InternalAddress.isInternal(ip: "::ffff:169.254.169.254"))
        #expect(!InternalAddress.isInternal(ip: "::ffff:8.8.8.8"))
    }

    /// Typing an address or `localhost` is an explicit choice to monitor
    /// something internal, and stays allowed — the check is only for names
    /// that hide where they point.
    @Test func recognisesDirectlyNamedHosts() {
        #expect(InternalAddress.isNamedDirectly(host: "192.168.1.50"))
        #expect(InternalAddress.isNamedDirectly(host: "127.0.0.1"))
        #expect(InternalAddress.isNamedDirectly(host: "::1"))
        #expect(InternalAddress.isNamedDirectly(host: "localhost"))
        #expect(InternalAddress.isNamedDirectly(host: "LOCALHOST"))
        #expect(InternalAddress.isNamedDirectly(host: "nas.local"))
        #expect(!InternalAddress.isNamedDirectly(host: "example.com"))
        #expect(!InternalAddress.isNamedDirectly(host: "internal.example.com"))
    }
}

@Suite struct HttpCheckerInternalTargetTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// `localhost` resolves to 127.0.0.1, but the user named it directly, so
    /// monitoring a local dev server keeps working.
    @Test func allowsAnExplicitlyNamedLocalTarget() async throws {
        #expect(await HttpChecker.internalTargetRefusal(for: try url("http://localhost:3000/health")) == nil)
        #expect(await HttpChecker.internalTargetRefusal(for: try url("http://192.168.1.50:8080")) == nil)
        #expect(await HttpChecker.internalTargetRefusal(for: try url("http://169.254.169.254/latest/meta-data/")) == nil)
    }

    /// A hostname that resolves inward is refused, and the message says which
    /// address it landed on rather than just "blocked".
    ///
    /// `localtest.me` is a public domain whose A record is 127.0.0.1, which
    /// makes it the real shape of the problem: an ordinary-looking name
    /// pointing at the loopback interface.
    @Test func refusesAHostnameThatResolvesToLoopback() async throws {
        let refusal = await HttpChecker.internalTargetRefusal(for: try url("http://localtest.me/admin"))
        // Skipped rather than failed when DNS is unavailable: this one test
        // needs the network, and a flaky resolver shouldn't fail the suite.
        try withKnownIssue(isIntermittent: true) {
            let message = try #require(refusal)
            // Either loopback form: the name has both an A and an AAAA
            // record, and which one the resolver lists first is its business.
            #expect(message.contains("127.0.0.1") || message.contains("::1"))
            #expect(message.contains("localtest.me"))
        } when: {
            refusal == nil
        }
    }

    @Test func allowsAnOrdinaryPublicTarget() async throws {
        let refusal = await HttpChecker.internalTargetRefusal(for: try url("https://example.com"))
        #expect(refusal == nil)
    }
}
