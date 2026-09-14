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

    /// Distinct per sensor, *not* the name: a Mac reports several sensors
    /// sharing one product string (two "PMU tdie7" dies at slightly different
    /// temperatures), which collided when the name was used as the `ForEach`
    /// identity. Defaults to the name so test fixtures stay readable.
    public let id: String
    public let name: String
    public let celsius: Double
    public let category: Category

    public init(name: String, celsius: Double, category: Category, id: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.celsius = celsius
        self.category = category
    }

    /// Buckets a sensor by its product name.
    ///
    /// Naming varies by chip generation, and none of it spells out "CPU":
    /// - Newer M-series report `PMU tdie{N}` — the SoC die sensors, which is
    ///   what "CPU temperature" means on a chip with no separate CPU package.
    ///   `PMU tdev{N}` (peripheral devices) and `PMU tcal` (calibration
    ///   reference) are *not* die sensors and stay out of the CPU bucket.
    /// - Earlier M-series report `pACC`/`eACC` (performance/efficiency core
    ///   clusters).
    /// - Intel Macs use plain "CPU"/"SOC" names.
    ///
    /// Anything unrecognised falls to `.system` rather than being dropped —
    /// an unknown board sensor is still useful in the "hottest sensors" list.
    public static func category(forSensorNamed name: String) -> Category {
        let lower = name.lowercased()
        if lower.contains("tdie") || lower.contains("pacc") || lower.contains("eacc")
            || lower.contains("cpu") || lower.contains("soc") {
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
