import AppKit
import DKBMonitorCore
import SwiftUI

/// Renders the app's panes to PNG offscreen, then exits. Enabled by setting
/// `DKBMONITOR_SNAPSHOT=<output directory>`; ignored otherwise, so it costs
/// a single environment lookup in a normal launch.
///
/// Exists because nothing else in the project checks *layout*. The test
/// suites cover parsing, repositories and view-model state, but a card that
/// overflows its row or a column that collapses is only ever caught by
/// launching the app and looking.
///
/// **What `ImageRenderer` can and cannot draw here**, established by
/// rendering each pane and inspecting the result:
/// - Text, shapes, bars, `Label`s, bordered buttons: accurate.
/// - `ScrollView`: renders as an empty rectangle — it has no scroll geometry
///   outside a real window. Hence `SystemView.content` /
///   `CleanupView.junkContent`, which are the page bodies lifted out of
///   their `ScrollView` precisely so they can be rendered here.
/// - `GroupBox`: renders blank. It's NSBox-backed on macOS, and its children
///   go with it. This currently rules out the System pane, whose every card
///   is a `GroupBox` — snapshotting it would mean replacing that with a
///   hand-drawn background, which would give up the automatic Liquid Glass
///   material the cards were deliberately built on. Not worth trading a
///   production look for a dev tool without asking first.
///
/// So the panes covered are the ones that don't depend on `GroupBox`.
@MainActor
enum LayoutSnapshot {
    static var requestedDirectory: String? {
        ProcessInfo.processInfo.environment["DKBMONITOR_SNAPSHOT"]
    }

    static func run(directory: String) async {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // One real sampling round so the live panes draw populated values
        // rather than the zeroed defaults `SystemStats()` starts at.
        SystemViewModel.shared.start()
        await MenuBarStatsViewModel.shared.refresh()
        try? await Task.sleep(for: .seconds(5))
        SystemViewModel.shared.stop()

        write(MenuBarContentView(), size: CGSize(width: 300, height: 460), to: url, name: "menubar-popover")
        write(CleanupView().junkContent, size: CGSize(width: 980, height: 760), to: url, name: "cleanup-junk")
        writeSyntheticMachineLayouts(to: url)

        print("Snapshots written to \(url.path)")
        exit(0)
    }

    /// The popover's per-core strip, rendered against machine shapes this Mac
    /// isn't. This is the part that pays for the whole tool: `CPUTopology`'s
    /// E/P grouping is unit-tested, but whether 24 core bars still fit a
    /// 300pt-wide popover can only be seen.
    ///
    /// Goes through the popover rather than the System pane's per-core grid
    /// because the latter is inside a `GroupBox` (see the type's note) and
    /// renders blank.
    private static func writeSyntheticMachineLayouts(to directory: URL) {
        let shapes: [(name: String, stats: SystemStats)] = [
            ("cores-m3max-4e12p", synthetic(clusters: [("Performance", 12), ("Efficiency", 4)])),
            ("cores-m2ultra-8e16p", synthetic(clusters: [("Performance", 16), ("Efficiency", 8)])),
            ("cores-intel-flat-8", synthetic(clusters: [])),
        ]
        // Pushed in *before* each render, not from an `.onAppear`:
        // `ImageRenderer` draws the view tree directly and never runs
        // appearance callbacks, so an `.onAppear`-based version renders every
        // shape identically.
        let model = MenuBarStatsViewModel.shared
        model.stop()
        for shape in shapes {
            model.overrideStatsForSnapshot(shape.stats)
            write(MenuBarContentView(), size: CGSize(width: 300, height: 460), to: directory, name: shape.name)
        }
    }

    private static func synthetic(clusters: [(String, Int)]) -> SystemStats {
        let topology = clusters.isEmpty
            ? CPUTopology.flat(coreCount: 8)
            : CPUTopology(levels: clusters.enumerated().map { index, cluster in
                CPUTopology.Level(index: index, name: cluster.0, coreCount: cluster.1)
            })
        let coreCount = topology.levels.reduce(0) { $0 + $1.coreCount }
        // Spread deterministically across 0-100 so every bar length differs
        // and a mis-sized grid cell is obvious.
        let cores = (0..<coreCount).map { Double(($0 * 37) % 101) }

        return SystemStats(
            cpuPercent: 46, cpuCores: cores, cpuTopology: topology,
            ramUsedMB: 12_400, ramTotalMB: 32_768,
            swapUsedMB: 1_024, swapTotalMB: 4_096,
            ramAppMB: 7_200, ramWiredMB: 3_100, ramCompressedMB: 2_100, ramCachedMB: 8_400,
            memoryPressureLevel: 2,
            diskUsedGB: 420, diskTotalGB: 994,
            cpuTempCelsius: 71,
            temperatures: [
                TemperatureReading(name: "pACC MTR Temp Sensor1", celsius: 71, category: .cpu),
                TemperatureReading(name: "GPU MTR Temp Sensor2", celsius: 58, category: .gpu),
                TemperatureReading(name: "NAND CH0 temp", celsius: 44, category: .system),
                TemperatureReading(name: "Gas Gauge Battery", celsius: 33, category: .battery),
            ],
            thermalStateRawValue: ProcessInfo.ThermalState.fair.rawValue,
            uptimeSecs: 291_600, fanRPMs: [2_100, 2_240]
        )
    }

    private static func write<V: View>(_ view: V, size: CGSize, to directory: URL, name: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else {
            print("Failed to render \(name)")
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
