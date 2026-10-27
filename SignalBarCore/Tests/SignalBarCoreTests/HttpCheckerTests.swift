import Testing
@testable import SignalBarCore

@Suite struct HttpCheckerTests {
    private func target(url: String, expectedStatus: Int = 200, customPath: String? = nil, expectedBodyContains: String? = nil) -> Target {
        Target(name: "T", url: url, expectedStatus: expectedStatus, customPath: customPath, expectedBodyContains: expectedBodyContains)
    }

    @Test func succeedsOnExpectedStatusAndBody() async {
        let outcome = await HttpChecker.check(target: target(url: "https://example.com", expectedBodyContains: "Example Domain"))
        #expect(outcome.success)
        #expect(outcome.statusCode == 200)
        #expect(outcome.errorMessage == nil)
    }

    @Test func failsWhenStatusMismatches() async {
        let outcome = await HttpChecker.check(target: target(url: "https://example.com", expectedStatus: 404))
        #expect(!outcome.success)
        #expect(outcome.statusCode == 200)
        #expect(outcome.errorMessage?.contains("Expected status 404") == true)
    }

    @Test func failsWhenBodyDoesNotContainExpectedText() async {
        let outcome = await HttpChecker.check(target: target(url: "https://example.com", expectedBodyContains: "text that will never appear"))
        #expect(!outcome.success)
        #expect(outcome.errorMessage == "Response body did not contain expected text")
    }

    @Test func failsGracefullyOnUnresolvableHost() async {
        let outcome = await HttpChecker.check(target: target(url: "https://this-host-does-not-exist.invalid"))
        #expect(!outcome.success)
        #expect(outcome.statusCode == nil)
        #expect(outcome.errorMessage != nil)
    }

    @Test func resolvesURLWithCustomPath() {
        let a = HttpChecker.resolvedURL(for: target(url: "https://example.com", customPath: "/status/200"))
        let b = HttpChecker.resolvedURL(for: target(url: "https://example.com/", customPath: "status/200"))
        #expect(a?.absoluteString == "https://example.com/status/200")
        #expect(b?.absoluteString == "https://example.com/status/200")
    }

    @Test func resolvesURLWithoutCustomPath() {
        let url = HttpChecker.resolvedURL(for: target(url: "https://example.com"))
        #expect(url?.absoluteString == "https://example.com")
    }
}
