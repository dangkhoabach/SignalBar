import Foundation

/// Manufacturer names by the first three bytes of a MAC address, from the
/// IEEE MA-L registry bundled as `oui.tsv` (built by `scripts/update-oui.sh`).
///
/// Looked up on the Mac rather than through an online "MAC vendor" service:
/// sending every device's address to a third party is exactly what this
/// feature promises not to do.
public struct OUIDatabase: Sendable {
    private let vendors: [UInt32: String]

    /// Loaded on first use, so an install that never opens Network pays nothing.
    public static let shared: OUIDatabase = {
        guard let url = Bundle.module.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return OUIDatabase(tsv: "") }
        return OUIDatabase(tsv: text)
    }()

    /// One `AABBCC<tab>Name` line per prefix.
    init(tsv: String) {
        var vendors: [UInt32: String] = [:]
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[0].count == 6, let prefix = UInt32(fields[0], radix: 16) else { continue }
            vendors[prefix] = String(fields[1])
        }
        self.vendors = vendors
    }

    /// `nil` for a private (locally administered) address, which belongs to
    /// no manufacturer whatever its first bytes say.
    public func vendor(for mac: MACAddress) -> String? {
        guard !mac.isLocallyAdministered, !mac.isGroup else { return nil }
        return vendors[mac.oui]
    }
}
