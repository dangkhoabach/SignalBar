import Foundation

/// Export/Import JSON format for the Overview's "Export/Import" feature —
/// a new format for this app (per Phase 11 decision), not required to be
/// compatible with the old Tauri app's export files. Round-trips through
/// `NewTargetInput`'s exact fields.
public struct ExportedTarget: Codable, Sendable {
    public var name: String
    public var url: String
    public var groupTag: String?
    public var checkIntervalSecs: Int
    public var checkHTTP: Bool
    public var expectedStatus: Int
    public var checkSSL: Bool
    public var checkDomain: Bool
    public var customPath: String?
    public var expectedBodyContains: String?

    public init(target: Target) {
        name = target.name
        url = target.url
        groupTag = target.groupTag
        checkIntervalSecs = target.checkIntervalSecs
        checkHTTP = target.checkHTTP
        expectedStatus = target.expectedStatus
        checkSSL = target.checkSSL
        checkDomain = target.checkDomain
        customPath = target.customPath
        expectedBodyContains = target.expectedBodyContains
    }

    public func asNewTargetInput() -> NewTargetInput {
        NewTargetInput(
            name: name, url: url, groupTag: groupTag, checkIntervalSecs: checkIntervalSecs,
            checkHTTP: checkHTTP, expectedStatus: expectedStatus, checkSSL: checkSSL, checkDomain: checkDomain,
            customPath: customPath, expectedBodyContains: expectedBodyContains
        )
    }
}

public enum TargetPortability {
    public static func export(targets: [Target]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(targets.map(ExportedTarget.init))
    }

    /// Returns the number of targets actually inserted — a duplicate URL
    /// (per `RepositoryError.duplicateURL`) is skipped rather than aborting
    /// the whole import, so a partially-overlapping file still imports what
    /// it can.
    @discardableResult
    public static func importInto(_ repo: TargetRepository, data: Data) throws -> Int {
        let items = try JSONDecoder().decode([ExportedTarget].self, from: data)
        var count = 0
        for item in items {
            do {
                _ = try repo.add(item.asNewTargetInput())
                count += 1
            } catch RepositoryError.duplicateURL {
                continue
            }
        }
        return count
    }
}
