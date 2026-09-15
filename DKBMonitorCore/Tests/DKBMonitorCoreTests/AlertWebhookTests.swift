import Foundation
import Testing
@testable import DKBMonitorCore

@Suite struct AlertWebhookTests {

    // MARK: - Destination

    /// Slack and Discord each accept only their own field name and reject
    /// anything else, so recognising the URL is what makes the payload land.
    @Test func slackAndDiscordWebhookURLsAreRecognised() throws {
        #expect(WebhookDestination.forURL(URL(string: "https://hooks.slack.com/services/T0/B0/xxx")!) == .slack)
        #expect(WebhookDestination.forURL(URL(string: "https://discord.com/api/webhooks/123/abc")!) == .discord)
        #expect(WebhookDestination.forURL(URL(string: "https://discordapp.com/api/webhooks/123/abc")!) == .discord)
    }

    /// A Discord URL that isn't a webhook endpoint must not be sent Discord's
    /// webhook payload.
    @Test func aNonWebhookDiscordURLIsTreatedAsGeneric() {
        #expect(WebhookDestination.forURL(URL(string: "https://discord.com/channels/123")!) == .generic)
    }

    @Test func anythingElseIsGeneric() {
        #expect(WebhookDestination.forURL(URL(string: "https://example.com/hook")!) == .generic)
        #expect(WebhookDestination.forURL(URL(string: "https://slack.example.com/hook")!) == .generic)
    }

    // MARK: - Payload

    @Test func slackGetsTextAndDiscordGetsContent() {
        let slack = AlertWebhook.payload(for: .slack, title: "a.com is down", body: "timeout", route: nil)
        #expect(slack == ["text": "a.com is down — timeout"])

        let discord = AlertWebhook.payload(for: .discord, title: "a.com is down", body: "timeout", route: nil)
        #expect(discord == ["content": "a.com is down — timeout"])
    }

    /// A generic receiver is code, so it gets the pieces rather than one
    /// prose line it would have to parse apart again.
    @Test func aGenericWebhookGetsSeparateFields() {
        let payload = AlertWebhook.payload(
            for: .generic, title: "a.com is down", body: "timeout", route: "/targets/1",
            sentAt: Date(timeIntervalSince1970: 0)
        )
        #expect(payload["title"] == "a.com is down")
        #expect(payload["body"] == "timeout")
        #expect(payload["route"] == "/targets/1")
        #expect(payload["source"] == "DKB Monitor")
        #expect(payload["sentAt"] != nil)
    }

    @Test func anAlertWithNoBodyIsStillReadable() {
        #expect(AlertWebhook.text(title: "a.com is down", body: "") == "a.com is down")
    }

    // MARK: - URL validation

    @Test func aPublicHTTPSURLIsAccepted() async {
        #expect(await AlertWebhook.validate("https://hooks.slack.com/services/T0/B0/xxx") == nil)
    }

    /// The alert carries the names of every monitored domain, so plain http
    /// would put them on the wire in the clear.
    @Test func httpIsRejected() async {
        #expect(await AlertWebhook.validate("http://example.com/hook") == .notHTTPS)
    }

    @Test func nonURLTextIsRejected() async {
        #expect(await AlertWebhook.validate("not a url") == .notAURL)
        #expect(await AlertWebhook.validate("") == .notAURL)
    }

    /// Same reasoning as the domain-monitoring SSRF guard: a user-supplied
    /// URL the app posts to on a schedule is exactly the shape that turns
    /// this app into someone's request proxy, and one aimed inward could
    /// reach services that trust the local network.
    @Test func anAddressOnTheLocalNetworkIsRejected() async {
        #expect(await AlertWebhook.validate("https://127.0.0.1/hook") == .internalAddress("127.0.0.1"))
        #expect(await AlertWebhook.validate("https://192.168.1.10/hook") == .internalAddress("192.168.1.10"))
        #expect(await AlertWebhook.validate("https://169.254.169.254/latest/meta-data") == .internalAddress("169.254.169.254"))
        #expect(await AlertWebhook.validate("https://[::1]/hook") == .internalAddress("::1"))
    }

    @Test func aPublicIPAddressIsAccepted() async {
        #expect(await AlertWebhook.validate("https://1.1.1.1/hook") == nil)
    }

    @Test func surroundingWhitespaceIsToleratedRatherThanRejected() async {
        #expect(await AlertWebhook.validate("  https://example.com/hook  ") == nil)
    }

    /// Every rejection has to say something the user can act on, since this
    /// text is the entire explanation they get in the Settings field.
    @Test func everyProblemExplainsItself() {
        for problem: WebhookURLProblem in [.notAURL, .notHTTPS, .internalAddress("10.0.0.1")] {
            #expect(!problem.message.isEmpty)
        }
        #expect(WebhookURLProblem.internalAddress("10.0.0.1").message.contains("10.0.0.1"))
    }
}
