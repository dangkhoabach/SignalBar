import Testing
@testable import DKBMonitorCore

@Suite struct TemperatureReadingTests {
    @Test func categorisesAppleSiliconCoreClusterSensors() {
        #expect(TemperatureReading.category(forSensorNamed: "pACC MTR Temp Sensor1") == .cpu)
        #expect(TemperatureReading.category(forSensorNamed: "eACC MTR Temp Sensor3") == .cpu)
        #expect(TemperatureReading.category(forSensorNamed: "SOC MTR Temp Sensor0") == .cpu)
    }

    /// Newer M-series name their die sensors `PMU tdie{N}` and expose no
    /// pACC/eACC/CPU string at all, so the earlier heuristic bucketed every
    /// one of them as `.system` and the UI showed no CPU reading.
    @Test func categorisesPMUDieSensorsAsCPU() {
        #expect(TemperatureReading.category(forSensorNamed: "PMU tdie1") == .cpu)
        #expect(TemperatureReading.category(forSensorNamed: "PMU tdie10") == .cpu)
    }

    /// Only the *die* sensors are the SoC. `tdev` are peripheral devices and
    /// `tcal` is a calibration reference — counting either as CPU would drag
    /// an unrelated reading into the headline temperature.
    @Test func doesNotTreatPeripheralOrCalibrationSensorsAsCPU() {
        #expect(TemperatureReading.category(forSensorNamed: "PMU tdev7") == .system)
        #expect(TemperatureReading.category(forSensorNamed: "PMU tcal") == .system)
        #expect(TemperatureReading.category(forSensorNamed: "NAND CH0 temp") == .system)
        #expect(TemperatureReading.category(forSensorNamed: "als-temp") == .system)
    }

    /// A Mac reports several sensors sharing one product string, which
    /// collided when the name doubled as the `ForEach` identity.
    @Test func identityIsDistinctForSensorsSharingAName() {
        let readings = [
            TemperatureReading(name: "PMU tdie7", celsius: 54.0, category: .cpu, id: "12"),
            TemperatureReading(name: "PMU tdie7", celsius: 53.3, category: .cpu, id: "13"),
        ]
        #expect(Set(readings.map(\.id)).count == 2)
    }

    @Test func identityFallsBackToTheNameWhenUnspecified() {
        #expect(TemperatureReading(name: "PMU tcal", celsius: 51.9, category: .system).id == "PMU tcal")
    }

    @Test func categorisesIntelAndPeripheralSensors() {
        #expect(TemperatureReading.category(forSensorNamed: "CPU Core 1") == .cpu)
        #expect(TemperatureReading.category(forSensorNamed: "GPU MTR Temp Sensor2") == .gpu)
        #expect(TemperatureReading.category(forSensorNamed: "Gas Gauge Battery") == .battery)
        #expect(TemperatureReading.category(forSensorNamed: "Battery Temp") == .battery)
    }

    /// An unrecognised board sensor must still be kept — it belongs in the
    /// "hottest sensors" list even though it fits no named bucket.
    @Test func categorisesUnknownSensorsAsSystem() {
        #expect(TemperatureReading.category(forSensorNamed: "NAND CH0 temp") == .system)
        #expect(TemperatureReading.category(forSensorNamed: "") == .system)
    }

    @Test func hottestPicksTheMaximumInACategory() {
        let readings = [
            TemperatureReading(name: "pACC", celsius: 62, category: .cpu),
            TemperatureReading(name: "eACC", celsius: 58, category: .cpu),
            TemperatureReading(name: "GPU", celsius: 44, category: .gpu),
        ]
        #expect(readings.hottest(.cpu) == 62)
        #expect(readings.hottest(.gpu) == 44)
        #expect(readings.hottest(.battery) == nil)
    }
}

@Suite struct CPUTopologyTests {
    private let m1: CPUTopology = .init(levels: [
        .init(index: 0, name: "Performance", coreCount: 4),
        .init(index: 1, name: "Efficiency", coreCount: 4),
    ])

    /// macOS numbers logical CPUs starting with the slowest level, so the
    /// first four cores of an M1 are the E-cores — getting this backwards
    /// would label every bar wrong without any build error to catch it.
    @Test func labelsEfficiencyCoresFirst() {
        #expect(m1.coreLabels() == ["E1", "E2", "E3", "E4", "P1", "P2", "P3", "P4"])
    }

    @Test func mapsEachCoreToItsLevel() {
        let levels = m1.coreLevels()
        #expect(levels.count == 8)
        #expect(levels[0].name == "Efficiency")
        #expect(levels[7].name == "Performance")
    }

    @Test func summarisesClustersSlowestFirst() {
        #expect(m1.summary == "4 Efficiency · 4 Performance")
    }

    /// Asymmetric cluster sizes (M3 Max: 4E + 12P) must not assume the
    /// clusters are equally sized.
    @Test func handlesAsymmetricClusters() {
        let m3Max = CPUTopology(levels: [
            .init(index: 0, name: "Performance", coreCount: 12),
            .init(index: 1, name: "Efficiency", coreCount: 4),
        ])
        let labels = m3Max.coreLabels()
        #expect(labels.count == 16)
        #expect(labels.prefix(4) == ["E1", "E2", "E3", "E4"])
        #expect(labels[4] == "P1")
        #expect(labels[15] == "P12")
    }

    /// Intel Macs report one performance level: plain numbers, no prefix.
    @Test func flatTopologyUsesBareNumbers() {
        let intel = CPUTopology.flat(coreCount: 8)
        #expect(!intel.hasClusters)
        #expect(intel.coreLabels() == ["1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(intel.summary == "8 cores")
    }
}

@Suite struct VolumeUsageTests {
    @Test func computesUsedBytesAndPercent() {
        let volume = VolumeUsage(path: "/", name: "Macintosh HD", totalBytes: 1000, freeBytes: 250, isInternal: true)
        #expect(volume.usedBytes == 750)
        #expect(volume.usedPercent == 75)
    }

    /// A volume reporting more free than total (seen on network mounts)
    /// must clamp to 0 rather than underflowing `UInt64`.
    @Test func clampsInconsistentFreeSpace() {
        let volume = VolumeUsage(path: "/net", name: "Share", totalBytes: 100, freeBytes: 500, isInternal: false)
        #expect(volume.usedBytes == 0)
        #expect(volume.usedPercent == 0)
    }

    @Test func emptyVolumeDoesNotDivideByZero() {
        let volume = VolumeUsage(path: "/empty", name: "Empty", totalBytes: 0, freeBytes: 0, isInternal: false)
        #expect(volume.usedPercent == 0)
    }
}
