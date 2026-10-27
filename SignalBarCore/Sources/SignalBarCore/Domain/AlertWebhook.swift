import Foundation

/// Why a webhook URL was refused, phrased for the Settings field that shows
/// it rather than for a log.
public enum WebhookURLProblem: Error, Sendable, Equatable {
    case notAURL
    case notHTTPS
    case internalAddress(String)

    public var message: String {
        switch self {
        case .notAURL:
            "That doesn't look like a URL. Paste the full address, starting with https://."
        case .notHTTPS:
            "Webhook URLs must use https. The alert carries your domain names, and http would send them in the clear."
        case .internalAddress(let host):
            "\(host) points at your own network rather than the public internet, so alerts sent there would never leave this Mac."
        }
    }
}

/// Where a webhook is being posted, which decides the JSON shape.
///
/// Slack and Discord each accept only their own field name and reject
/// anything else with a 400, so "just send JSON" doesn't work — the
/// destination has to be recognised. Anything unrecognised gets a
/// self-describing payload instead of being made to look like one of those
/// two.
public enum WebhookDestination: Sendable, Equatable {
    case slack
    case discord
    case generic

    public static func forURL(_ url: URL) -> WebhookDestination {
        guard let host = url.host?.lowercased() else { return .generic }
        if host == "hooks.slack.com" || host.hasSuffix(".slack.com") { return .slack }
        if host == "discord.com" || host == "discordapp.com" || host.hasSuffix(".discord.com") {
            return url.path.contains("/api/webhooks") ? .discord : .generic
        }
        return .generic
    }
}

/// Builds the body posted to a webhook, and validates the URL it goes to.
///
/// Kept apart from the sending itself so both can be tested without a
/// network: the shape of the payload and the decision to refuse a URL are
/// where the behaviour actually lives.
public enum AlertWebhook {
    /// Checks the URL before it is ever stored, so a bad one is rejected in
    /// the Settings field rather than failing silently at 3am.
    ///
    /// The internal-address check is the same one domain monitoring uses: a
    /// user-supplied URL the app will POST to on a schedule is exactly the
    /// shape that turns an app into someone's request proxy, and a webhook
    /// aimed inward could also reach services that trust the local network.
    public static func validate(_ raw: String) async -> WebhookURLProblem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return .notAURL
        }
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }

        if InternalAddress.isNamedDirectly(host: host) {
            return InternalAddress.isInternal(ip: host) ? .internalAddress(host) : nil
        }
        let addresses = await InternalAddress.resolve(host: host)
        if let inward = addresses.first(where: InternalAddress.isInternal(ip:)) {
            return .internalAddress(inward)
        }
        return nil
    }

    /// The one-line text every destination shows, whatever wrapper it needs.
    public static func text(title: String, body: String) -> String {
        body.isEmpty ? title : "\(title) — \(body)"
    }

    public static func payload(
        for destination: WebhookDestination,
        title: String,
        body: String,
        route: String?,
        sentAt: Date = Date()
    ) -> [String: String] {
        switch destination {
        case .slack:
            return ["text": text(title: title, body: body)]
        case .discord:
            return ["content": text(title: title, body: body)]
        case .generic:
            // Separate fields rather than one prose string: a generic
            // receiver is code, and code would otherwise have to parse the
            // message back apart.
            var payload = [
                "source": "SignalBar",
                "title": title,
                "body": body,
                "sentAt": ISO8601DateFormatter().string(from: sentAt),
            ]
            if let route { payload["route"] = route }
            return payload
        }
    }
}
