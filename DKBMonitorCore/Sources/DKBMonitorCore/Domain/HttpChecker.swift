import Foundation

public struct HttpCheckOutcome: Sendable, Equatable {
    public let success: Bool
    public let statusCode: Int?
    public let responseTimeMs: Int
    public let errorMessage: String?
}

/// Ports `run_check` from the Rust scheduler: GET the target's URL (optionally
/// appending `customPath`), and succeed only if both the status code and body
/// substring (when configured) match expectations.
public enum HttpChecker {
    private static let timeout: TimeInterval = 10
    /// A single transient network-level blip (timeout/DNS hiccup) shouldn't
    /// count as a full failure on its own - retried once, after a short
    /// delay, before being reported. Only retries network-level failures
    /// (no HTTP response at all); a legitimate wrong-status/wrong-body
    /// response is not retried since it isn't transient.
    private static let retryDelay: UInt64 = 1_000_000_000

    public static func check(target: Target) async -> HttpCheckOutcome {
        let first = await performCheck(target: target)
        guard first.statusCode == nil else { return first }
        try? await Task.sleep(nanoseconds: retryDelay)
        return await performCheck(target: target)
    }

    private static func performCheck(target: Target) async -> HttpCheckOutcome {
        let started = Date()
        guard let url = resolvedURL(for: target) else {
            return HttpCheckOutcome(success: false, statusCode: nil, responseTimeMs: 0, errorMessage: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return HttpCheckOutcome(success: false, statusCode: nil, responseTimeMs: elapsedMs, errorMessage: "Invalid response")
            }

            let statusOk = http.statusCode == target.expectedStatus
            let bodyOk: Bool
            if let needle = target.expectedBodyContains, !needle.isEmpty {
                bodyOk = String(data: data, encoding: .utf8)?.contains(needle) ?? false
            } else {
                bodyOk = true
            }

            let errorMessage: String?
            if statusOk && bodyOk {
                errorMessage = nil
            } else if !statusOk {
                errorMessage = "Expected status \(target.expectedStatus), got \(http.statusCode)"
            } else {
                errorMessage = "Response body did not contain expected text"
            }

            return HttpCheckOutcome(success: statusOk && bodyOk, statusCode: http.statusCode, responseTimeMs: elapsedMs, errorMessage: errorMessage)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return HttpCheckOutcome(success: false, statusCode: nil, responseTimeMs: elapsedMs, errorMessage: error.localizedDescription)
        }
    }

    static func resolvedURL(for target: Target) -> URL? {
        guard let path = target.customPath, !path.isEmpty else {
            return URL(string: target.url)
        }
        let base = target.url.hasSuffix("/") ? String(target.url.dropLast()) : target.url
        let separator = path.hasPrefix("/") ? "" : "/"
        return URL(string: "\(base)\(separator)\(path)")
    }
}
