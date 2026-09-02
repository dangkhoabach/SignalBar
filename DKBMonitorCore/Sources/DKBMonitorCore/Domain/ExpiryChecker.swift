import Foundation
import Security

/// SSL certificate + domain-registration expiry checks. Replaces the Rust
/// version's `openssl s_client` shell-out (SSL) and RDAP-with-`whois`-fallback
/// (domain) with native equivalents: `SecTrust` for the certificate, and
/// `URLSession`/`Process` for RDAP/whois respectively.
public enum ExpiryChecker {
    private static let sslTimeout: TimeInterval = 10
    private static let domainTimeout: TimeInterval = 20

    enum SSLError: Error {
        case noCertificate
        case noExpiryField
    }

    /// Connects to `host:443`, completes the TLS handshake, and reads the leaf
    /// certificate's "not valid after" date. Deliberately does not validate
    /// trust — self-signed/expired certs should still report their real
    /// expiry, matching the previous `openssl s_client` behavior.
    public static func checkSSLExpiry(host: String) async -> Date? {
        await withTimeout(sslTimeout) {
            try? await fetchSSLExpiryDate(host: host)
        }
    }

    /// Prefers RDAP (single HTTPS request) over `whois` (two chained
    /// round-trips with no built-in read timeout); `whois` remains a fallback
    /// for TLDs without an RDAP server (notably `.vn`).
    public static func checkDomainExpiry(domain: String) async -> Date? {
        await withTimeout(domainTimeout) {
            if let date = await rdapDomainExpiry(domain: domain) {
                return date
            }
            return await whoisDomainExpiry(domain: domain)
        }
    }

    // MARK: - SSL

    private static func fetchSSLExpiryDate(host: String) async throws -> Date {
        final class TrustCapturingDelegate: NSObject, URLSessionDelegate {
            nonisolated(unsafe) var capturedTrust: SecTrust?
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                if let trust = challenge.protectionSpace.serverTrust {
                    capturedTrust = trust
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            }
        }

        let delegate = TrustCapturingDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = sslTimeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host)/") else { throw SSLError.noCertificate }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)

        guard let trust = delegate.capturedTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            throw SSLError.noCertificate
        }

        guard let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let validity = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let secondsSince2001 = validity[kSecPropertyKeyValue] as? Double
        else {
            throw SSLError.noExpiryField
        }

        return Date(timeIntervalSinceReferenceDate: secondsSince2001)
    }

    // MARK: - Domain (RDAP)

    private static func rdapDomainExpiry(domain: String) async -> Date? {
        guard let tld = domain.split(separator: ".").last.map({ String($0).lowercased() }),
              var base = await RDAPBootstrap.shared.baseURL(forTLD: tld)
        else {
            return nil
        }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/domain/\(domain)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/rdap+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let expiryEvent = events.first(where: { ($0["eventAction"] as? String) == "expiration" }),
              let rawDate = expiryEvent["eventDate"] as? String
        else {
            return nil
        }
        return parseRFC3339(rawDate)
    }

    private static func parseRFC3339(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Domain (whois fallback)

    private static let expiryLinePatterns = [
        "registry expiry date:",
        "registrar registration expiration date:",
        "expiration date:",
        "expiry date:",
        "paid-till:",
        "expire date:",
    ]

    private static func whoisDomainExpiry(domain: String) async -> Date? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/whois")
                process.arguments = [domain]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + domainTimeout, execute: timeoutWorkItem)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseWhoisExpiry(text))
            }
        }
    }

    static func parseWhoisExpiry(_ text: String) -> Date? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for pattern in expiryLinePatterns {
                if let range = line.range(of: pattern, options: .caseInsensitive) {
                    let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let date = normalizeWhoisDate(value) {
                        return date
                    }
                }
            }
        }
        return nil
    }

    private static func normalizeWhoisDate(_ raw: String) -> Date? {
        let cleaned = raw.split(whereSeparator: { $0 == "T" || $0 == " " }).first.map(String.init) ?? raw
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: cleaned)
    }

    // MARK: - Timeout helper

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = (await group.next()) ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// TLD -> RDAP base URL, per IANA's bootstrap registry. Fetched once and
/// cached for the process lifetime (the mapping essentially never changes at
/// runtime).
actor RDAPBootstrap {
    static let shared = RDAPBootstrap()

    private var cache: [String: String]?

    func baseURL(forTLD tld: String) async -> String? {
        // Only cache a non-empty result - `fetch()` returns `[:]` (not nil)
        // on failure (no network, DNS hiccup, data.iana.org timeout), and an
        // empty dict cached here would silently stick for the rest of the
        // process lifetime, forcing every later lookup onto the slower
        // `whois` fallback even after the network recovers.
        if cache == nil || cache?.isEmpty == true {
            cache = await Self.fetch()
        }
        return cache?[tld]
    }

    private static func fetch() async -> [String: String] {
        guard let url = URL(string: "https://data.iana.org/rdap/dns.json") else { return [:] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = json["services"] as? [[Any]]
        else {
            return [:]
        }

        var map: [String: String] = [:]
        for entry in services {
            guard entry.count >= 2,
                  let tlds = entry[0] as? [String],
                  let urls = entry[1] as? [String],
                  let baseURL = urls.first
            else { continue }
            for tld in tlds { map[tld.lowercased()] = baseURL }
        }
        return map
    }
}
