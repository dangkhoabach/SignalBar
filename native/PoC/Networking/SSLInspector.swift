import Foundation
import Security

/// PoC: reads a TLS certificate's expiry date natively via SecTrust, no
/// shelling out to `openssl s_client` like the current Rust implementation
/// does on macOS/Linux (Windows already does something similar via
/// PowerShell/.NET SslStream — this proves the same is possible, and simpler,
/// on macOS with a first-party API).
enum SSLInspector {
    enum InspectorError: Error {
        case noCertificate
        case noExpiryField
    }

    /// Connects to `host:443`, completes the TLS handshake, and reads the
    /// leaf certificate's "not valid after" date — deliberately does NOT
    /// validate trust (self-signed / expired-but-still-readable certs should
    /// still report their real expiry, matching the current `openssl
    /// s_client` behavior which also doesn't verify the chain).
    static func fetchExpiryDate(host: String, timeout: TimeInterval = 10) async throws -> Date {
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
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host)/") else { throw InspectorError.noCertificate }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        // A HEAD request is enough to force the TLS handshake (and thus the
        // auth challenge above) — we don't care about the HTTP response body,
        // only about the certificate captured during the handshake.
        _ = try? await session.data(for: request)

        guard let trust = delegate.capturedTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            throw InspectorError.noCertificate
        }

        guard let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let validity = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let secondsSince2001 = validity[kSecPropertyKeyValue] as? Double
        else {
            throw InspectorError.noExpiryField
        }

        // SecCertificate's validity dates are seconds since the Core
        // Foundation reference date (2001-01-01), not Unix epoch.
        return Date(timeIntervalSinceReferenceDate: secondsSince2001)
    }
}
