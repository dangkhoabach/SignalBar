import Foundation
import Testing
@testable import SignalBarCore

@Suite struct ExpiryCheckerTests {
    @Test func sslExpiryIsReadForAStableRealHost() async throws {
        let expiry = await ExpiryChecker.checkSSLExpiry(host: "github.com")
        let date = try #require(expiry)
        #expect(date > Date())
    }

    @Test func sslExpiryIsNilForUnresolvableHost() async {
        let expiry = await ExpiryChecker.checkSSLExpiry(host: "this-host-does-not-exist.invalid")
        #expect(expiry == nil)
    }

    @Test func domainExpiryViaRDAPForADotComDomain() async throws {
        // .com has a well-known, always-available RDAP server (Verisign) —
        // this exercises the primary (non-whois-fallback) path end-to-end.
        let expiry = await ExpiryChecker.checkDomainExpiry(domain: "github.com")
        let date = try #require(expiry)
        #expect(date > Date())
    }

    // Whois parsing (the .vn / no-RDAP fallback path) is tested against fixed
    // sample text below rather than a live `whois` call, to keep the suite
    // deterministic regardless of local `whois` availability/rate limits.
    @Test func parsesWhoisExpiryLineVariants() {
        let samples: [(String, String)] = [
            ("Registry Expiry Date: 2030-01-15T00:00:00Z", "2030-01-15"),
            ("Registrar Registration Expiration Date: 2029-06-01T00:00:00Z", "2029-06-01"),
            ("paid-till: 2031-12-31T00:00:00Z", "2031-12-31"),
            ("Expiration Date: 2028-03-03 00:00:00", "2028-03-03"),
        ]
        for (line, expectedDay) in samples {
            let date = ExpiryChecker.parseWhoisExpiry(line)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            #expect(date.map(formatter.string) == expectedDay)
        }
    }

    @Test func whoisParsingReturnsNilWhenNoExpiryLinePresent() {
        #expect(ExpiryChecker.parseWhoisExpiry("Domain Name: EXAMPLE.COM\nStatus: active") == nil)
    }
}
