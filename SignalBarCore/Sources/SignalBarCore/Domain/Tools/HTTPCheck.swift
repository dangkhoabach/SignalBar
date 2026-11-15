import Foundation
import Security

public struct CertificateSummary: Sendable, Equatable, Identifiable {
    public var subject: String
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// The names it is valid for (Subject Alternative Names).
    public var dnsNames: [String] = []
    public var id: String { "\(subject)|\(notAfter?.timeIntervalSince1970 ?? 0)" }
}

public struct HTTPRedirect: Sendable, Equatable, Identifiable {
    public var url: String
    public var status: Int
    public var location: String
    public var id: String { url + location }
}

public struct HTTPCheckResult: Sendable, Equatable {
    public var requestedURL: String
    public var finalURL: String?
    public var status: Int?
    public var headers: [(name: String, value: String)] = []
    public var redirects: [HTTPRedirect] = []
    public var bodyBytes = 0
    /// Of the last request, in milliseconds; `nil` when that step didn't happen (a reused connection).
    public var dnsMilliseconds: Double?
    public var connectMilliseconds: Double?
    public var tlsMilliseconds: Double?
    public var firstByteMilliseconds: Double?
    public var totalMilliseconds: Double?
    public var remoteAddress: String?
    public var httpVersion: String?
    public var tlsVersion: String?
    public var certificates: [CertificateSummary] = []
    public var error: String?

    public static func == (lhs: HTTPCheckResult, rhs: HTTPCheckResult) -> Bool {
        lhs.requestedURL == rhs.requestedURL && lhs.finalURL == rhs.finalURL && lhs.status == rhs.status
            && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
            && lhs.redirects == rhs.redirects && lhs.bodyBytes == rhs.bodyBytes && lhs.totalMilliseconds == rhs.totalMilliseconds
            && lhs.remoteAddress == rhs.remoteAddress && lhs.certificates == rhs.certificates && lhs.error == rhs.error
    }
}

public enum HTTPCheckError: Error, Equatable, Sendable {
    case invalidURL
}

extension HTTPCheckError: LocalizedError {
    public var errorDescription: String? { "Enter an http:// or https:// address." }
}

/// One GET request, timed step by step, with the redirects it went through
/// and the certificate chain the server presented.
public enum HTTPCheck {
    /// Adds `https://` to a bare host name.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    public static func run(_ text: String, followRedirects: Bool = true, timeout: Double = 20) async throws -> HTTPCheckResult {
        guard let url = url(from: text) else { throw HTTPCheckError.invalidURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let recorder = Recorder(followRedirects: followRedirects)
        var result = HTTPCheckResult(requestedURL: url.absoluteString)
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url), delegate: recorder)
            if let http = response as? HTTPURLResponse {
                result.status = http.statusCode
                result.finalURL = http.url?.absoluteString
                result.headers = http.allHeaderFields
                    .map { (name: "\($0.key)", value: "\($0.value)") }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
            }
            result.bodyBytes = data.count
        } catch {
            result.error = error.localizedDescription
        }
        let recorded = recorder.snapshot()
        result.redirects = recorded.redirects
        result.certificates = recorded.certificates
        if let metrics = recorded.metrics {
            apply(metrics, to: &result)
        }
        return result
    }

    private static func apply(_ metrics: URLSessionTaskMetrics, to result: inout HTTPCheckResult) {
        guard let last = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) ?? metrics.transactionMetrics.last
        else { return }
        func span(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start) * 1000
        }
        result.dnsMilliseconds = span(last.domainLookupStartDate, last.domainLookupEndDate)
        result.connectMilliseconds = span(last.connectStartDate, last.secureConnectionStartDate ?? last.connectEndDate)
        result.tlsMilliseconds = span(last.secureConnectionStartDate, last.secureConnectionEndDate)
        result.firstByteMilliseconds = span(last.requestStartDate, last.responseStartDate)
        result.totalMilliseconds = metrics.taskInterval.duration * 1000
        result.remoteAddress = last.remoteAddress.map { address in last.remotePort.map { "\(address):\($0)" } ?? address }
        result.httpVersion = last.networkProtocolName
        result.tlsVersion = last.negotiatedTLSProtocolVersion.map(tlsName)
    }

    private static func tlsName(_ version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv13: "TLS 1.3"
        case .TLSv12: "TLS 1.2"
        case .TLSv11: "TLS 1.1"
        case .TLSv10: "TLS 1.0"
        default: "TLS"
        }
    }

    static func summary(of certificate: SecCertificate) -> CertificateSummary {
        var summary = CertificateSummary(subject: SecCertificateCopySubjectSummary(certificate) as String? ?? "?")
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1IssuerName, kSecOIDSubjectAltName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] else { return summary }
        func date(_ key: CFString) -> Date? {
            (values[key as String]?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        summary.notBefore = date(kSecOIDX509V1ValidityNotBefore)
        summary.notAfter = date(kSecOIDX509V1ValidityNotAfter)
        let issuerParts = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        summary.issuer = (issuerParts.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) }
            ?? issuerParts.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationName as String) })?[kSecPropertyKeyValue as String] as? String
        let names = values[kSecOIDSubjectAltName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        summary.dnsNames = names.filter { ($0[kSecPropertyKeyLabel as String] as? String) == "DNS Name" }.compactMap { $0[kSecPropertyKeyValue as String] as? String }
        return summary
    }

    /// The task's delegate: notes each redirect, the server's certificates and the timings.
    private final class Recorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        struct Recorded {
            var redirects: [HTTPRedirect] = []
            var certificates: [CertificateSummary] = []
            var metrics: URLSessionTaskMetrics?
        }

        private let followRedirects: Bool
        private let lock = NSLock()
        private var recorded = Recorded()

        init(followRedirects: Bool) {
            self.followRedirects = followRedirects
        }

        func snapshot() -> Recorded { lock.withLock { recorded } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            lock.withLock {
                recorded.redirects.append(HTTPRedirect(url: response.url?.absoluteString ?? "", status: response.statusCode,
                                                       location: request.url?.absoluteString ?? ""))
            }
            return followRedirects ? request : nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                let summaries = chain.map(HTTPCheck.summary)
                lock.withLock { recorded.certificates = summaries }
            }
            // The system decides whether to trust it; a bad certificate shows up as the request's error.
            return (.performDefaultHandling, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { recorded.metrics = metrics }
        }
    }
}
