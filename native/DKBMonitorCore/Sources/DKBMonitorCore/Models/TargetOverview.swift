import Foundation

/// Composed read-model for the Overview list — not a GRDB record itself,
/// assembled by TargetRepository from several tables per target.
public struct TargetOverview: Equatable, Sendable {
    public var target: Target
    public var latestCheck: CheckResult?
    public var sslStatus: SslStatus?
    public var domainStatus: DomainStatus?
    public var uptime24hPct: Double?

    public init(target: Target, latestCheck: CheckResult?, sslStatus: SslStatus?, domainStatus: DomainStatus?, uptime24hPct: Double?) {
        self.target = target
        self.latestCheck = latestCheck
        self.sslStatus = sslStatus
        self.domainStatus = domainStatus
        self.uptime24hPct = uptime24hPct
    }
}

public struct TargetDetail: Equatable, Sendable {
    public var target: Target
    public var sslStatus: SslStatus?
    public var domainStatus: DomainStatus?
    public var uptime24hPct: Double?
    public var uptime7dPct: Double?
    public var history: [CheckResult]
    public var incidents: [Incident]

    public init(
        target: Target,
        sslStatus: SslStatus?,
        domainStatus: DomainStatus?,
        uptime24hPct: Double?,
        uptime7dPct: Double?,
        history: [CheckResult],
        incidents: [Incident]
    ) {
        self.target = target
        self.sslStatus = sslStatus
        self.domainStatus = domainStatus
        self.uptime24hPct = uptime24hPct
        self.uptime7dPct = uptime7dPct
        self.history = history
        self.incidents = incidents
    }
}

/// A run of consecutive failed checks, derived from `check_results` rather
/// than stored directly. `endedAt` is `nil` while the incident is still
/// ongoing (the most recent check in the run is still a failure).
public struct Incident: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var errorMessage: String?

    public init(startedAt: Date, endedAt: Date?, errorMessage: String?) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorMessage = errorMessage
    }
}

extension Array where Element == CheckResult {
    /// Groups consecutive failed checks into incidents. `self` must be in
    /// `checkedAt` DESC order (most-recent-first, as the repository queries
    /// return it); this walks it in reverse (chronological) order to build
    /// each incident's start/end, then returns most-recent-first to match.
    public func buildIncidents() -> [Incident] {
        var incidents: [Incident] = []
        var open: Incident?

        for check in self.reversed() {
            if !check.success {
                if open == nil {
                    open = Incident(startedAt: check.checkedAt, endedAt: nil, errorMessage: check.errorMessage)
                }
            } else if let incident = open {
                incidents.append(Incident(startedAt: incident.startedAt, endedAt: check.checkedAt, errorMessage: incident.errorMessage))
                open = nil
            }
        }
        if let incident = open {
            incidents.append(incident) // still ongoing as of the most recent check
        }

        return incidents.reversed()
    }
}
