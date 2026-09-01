import Testing
@testable import DKBMonitorCore

@Suite struct HostParsingTests {
    @Test func groupsSubdomainsUnderRootDomain() {
        #expect(HostParsing.resolveGroupTag(explicit: nil, url: "https://dangkhoabach.vn") == "dangkhoabach.vn")
        #expect(HostParsing.resolveGroupTag(explicit: nil, url: "https://tools.dangkhoabach.vn") == "dangkhoabach.vn")
        #expect(HostParsing.resolveGroupTag(explicit: nil, url: "https://admin.dangkhoabach.vn") == "dangkhoabach.vn")
    }

    @Test func explicitGroupWins() {
        #expect(HostParsing.resolveGroupTag(explicit: "Custom", url: "https://tools.dangkhoabach.vn") == "Custom")
    }

    @Test func blankExplicitGroupFallsBackToDomain() {
        #expect(HostParsing.resolveGroupTag(explicit: "", url: "https://tools.dangkhoabach.vn") == "dangkhoabach.vn")
    }

    @Test func handlesTwoPartCcSLD() {
        #expect(HostParsing.extractRegistrableDomain("www.example.co.uk") == "example.co.uk")
        #expect(HostParsing.extractRegistrableDomain("shop.example.com.vn") == "example.com.vn")
    }

    @Test func plainTwoLabelDomainUnaffected() {
        #expect(HostParsing.extractRegistrableDomain("example.com") == "example.com")
    }
}
