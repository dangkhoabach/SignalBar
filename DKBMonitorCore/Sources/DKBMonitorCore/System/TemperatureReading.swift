import Foundation

/// One thermal sensor reading. Apple Silicon exposes dozens of these (SoC
/// core clusters, GPU, battery gas gauge, ambient/board sensors), each named
/// only by an opaque product string — `category` buckets them so the UI can
/// summarise "CPU 62°C / GPU 48°C" instead of listing 50 raw names.
///
/// Lives here (not the app target) because the bucketing is pure string
/// logic worth testing headlessly; the IOKit reading that produces these
/// values stays in `HIDThermalReader`, same split as `SystemStats` /
/// `SystemStatsService`.
public struct TemperatureReading: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case cpu, gpu, battery, system
    }

    public var id: String { name }
    public let name: String
    public let celsius: Double
    public let category: Category

    public init(name: String, celsius: Double, category: Category) {
        self.name = name
        self.celsius = celsius
        self.category = category
    }

    /// Buckets a sensor by its product name. Apple Silicon names the core
    /// clusters `pACC`/`eACC` (performance/efficiency) and never spells out
    /// "CPU"; Intel Macs do use plain "CPU"/"TCxx" names, so both spellings
    /// are matched. Anything unrecognised falls to `.system` rather than
    /// being dropped — an unknown board sensor is still useful in the
    /// "hottest sensors" list.
    public static func category(forSensorNamed name: String) -> Category {
        let lower = name.lowercased()
        if lower.contains("pacc") || lower.contains("eacc") || lower.contains("cpu") || lower.contains("soc") {
            return .cpu
        }
        if lower.contains("gpu") { return .gpu }
        if lower.contains("battery") || lower.contains("gas gauge") { return .battery }
        return .system
    }
}

extension Array where Element == TemperatureReading {
    /// Hottest reading in a category, or `nil` when this Mac exposes none.
    public func hottest(_ category: TemperatureReading.Category) -> Double? {
        lazy.filter { $0.category == category }.map(\.celsius).max()
    }
}
