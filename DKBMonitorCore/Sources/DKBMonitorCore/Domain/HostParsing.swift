import Foundation

/// Best-effort host/registrable-domain extraction — not a full public-suffix-
/// list implementation, same scope as the current Rust version (handles
/// common two-part ccSLDs like .co.uk / .com.vn).
public enum HostParsing {
    public static func extractHost(fromURL urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    /// Lets the user type a bare domain ("example.com") instead of requiring
    /// a scheme — everything downstream (`HttpChecker`, `extractHost`,
    /// `URLSession`) needs `target.url` to already have one, so this is the
    /// single normalization point both the Add/Edit form and JSON import go
    /// through (`TargetRepository.add`/`update`).
    public static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }

    private static let ccSecondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu"]

    public static func extractRegistrableDomain(_ host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        let last = parts[parts.count - 1]
        let secondLast = parts[parts.count - 2]
        if last.count == 2, ccSecondLevel.contains(secondLast) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Uses the caller's explicit group if given; otherwise groups the target
    /// under its registrable root domain so related subdomains organize
    /// themselves without the user typing anything.
    public static func resolveGroupTag(explicit: String?, url: String) -> String? {
        if let tag = explicit?.trimmingCharacters(in: .whitespaces), !tag.isEmpty {
            return tag
        }
        guard let host = extractHost(fromURL: url) else { return nil }
        return extractRegistrableDomain(host)
    }
}
