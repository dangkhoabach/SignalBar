import CoreGraphics
import Testing
@testable import SignalBarCore

@Suite struct OverlayMetricListTests {
    @Test func aListRoundTripsInOrder() {
        let metrics: [OverlayMetric] = [.gpu, .cpu, .network, .uptime]
        #expect(OverlayMetric.parse(csv: OverlayMetric.csv(metrics)) == metrics)
    }

    /// A newer build may store a metric this build doesn't know.
    @Test func unknownIdsAndRepeatsAreSkipped() {
        #expect(OverlayMetric.parse(csv: "cpu,fps,gpu,cpu") == [.cpu, .gpu])
    }

    @Test func neverSavedMeansDefaultsAndNoneMeansEmpty() {
        #expect(OverlayMetric.parse(csv: "") == OverlayMetric.defaultMetrics)
        #expect(OverlayMetric.parse(csv: OverlayMetric.noneMarker) == [])
    }
}

@Suite struct OverlayDisplayTests {
    @Test func everyCaseRoundTrips() {
        for display in [OverlayDisplay.main, .mouse, .named("Studio Display")] {
            #expect(OverlayDisplay(rawValue: display.rawValue) == display)
        }
    }

    @Test func unknownOrEmptyNameFallsBackToMain() {
        #expect(OverlayDisplay(rawValue: "garbage") == .main)
        #expect(OverlayDisplay(rawValue: "name:") == .main)
    }
}

@Suite struct OverlayRingTests {
    @Test func keepsOnlyTheNewestValuesOldestFirst() {
        var ring = OverlayRing(capacity: 3)
        for value in 1...5 { ring.append(Double(value)) }
        #expect(ring.count == 3)
        #expect(ring.values == [3, 4, 5])
    }

    @Test func partlyFilledRingKeepsInsertionOrder() {
        var ring = OverlayRing(capacity: 60)
        ring.append(7)
        ring.append(8)
        #expect(ring.values == [7, 8])
    }
}

@Suite struct OverlayFormatterTests {
    private func read(_ metric: OverlayMetric, _ sample: OverlaySample) -> OverlayReading? {
        OverlayFormatter.reading(metric, in: sample)
    }

    /// A metric this Mac can't read hides its row — every case, so a new
    /// metric can't slip in that prints a fake zero.
    @Test func everyMetricIsHiddenWithoutAReading() {
        for metric in OverlayMetric.allCases {
            #expect(read(metric, OverlaySample()) == nil, "\(metric)")
        }
    }

    @Test func loadUsesThePopoverThresholds() {
        #expect(read(.cpu, OverlaySample(cpuPercent: 42.4)) == OverlayReading("42%"))
        #expect(read(.cpu, OverlaySample(cpuPercent: 70)) == OverlayReading("70%", .warning))
        #expect(read(.gpu, OverlaySample(gpuPercent: 90)) == OverlayReading("90%", .critical))
        #expect(read(.gpu, OverlaySample(gpuPercent: 0)) == OverlayReading("0%"))
    }

    @Test func temperatureUsesThePopoverThresholds() {
        #expect(read(.cpuTemp, OverlaySample(cpuTempCelsius: 46.7)) == OverlayReading("47°C"))
        #expect(read(.gpuTemp, OverlaySample(gpuTempCelsius: 70)) == OverlayReading("70°C", .warning))
        #expect(read(.cpuTemp, OverlaySample(cpuTempCelsius: 85)) == OverlayReading("85°C", .critical))
    }

    /// Colour follows memory pressure, not "% used".
    @Test func memoryIsColouredByPressure() {
        let sample = OverlaySample(ramUsedMB: 12_697, ramTotalMB: 32_768, memoryPressureLevel: 2)
        #expect(read(.memory, sample) == OverlayReading("12.4/32 GB", .warning))
        #expect(read(.memory, OverlaySample(ramUsedMB: 1, ramTotalMB: 0)) == nil)
    }

    @Test func networkSwitchesUnitsAtOneThousandKB() {
        let sample = OverlaySample(downloadKbps: 1536, uploadKbps: 35.4)
        #expect(read(.network, sample) == OverlayReading("↓1.5 MB/s ↑35 KB/s"))
    }

    @Test func sizesSwitchToGigabytes() {
        #expect(read(.swap, OverlaySample(swapUsedMB: 512)) == OverlayReading("512 MB"))
        #expect(read(.gpuMemory, OverlaySample(gpuMemoryMB: 2048)) == OverlayReading("2.0 GB"))
    }

    /// An idle fan reads 0 rpm, which is a real reading.
    @Test func fansListEveryFan() {
        #expect(read(.fan, OverlaySample(fanRPMs: [0, 2240.4])) == OverlayReading("0/2240 rpm"))
    }

    @Test func batteryWarnsOnlyWhenDischarging() {
        #expect(read(.battery, OverlaySample(batteryPercent: 15, batteryCharging: false)) == OverlayReading("15%", .warning))
        #expect(read(.battery, OverlaySample(batteryPercent: 8, batteryCharging: false)) == OverlayReading("8%", .critical))
        #expect(read(.battery, OverlaySample(batteryPercent: 8, batteryCharging: true)) == OverlayReading("8% ⚡︎"))
    }

    @Test func powerDisplayAndUptime() {
        #expect(read(.power, OverlaySample(systemPowerWatts: 5.58)) == OverlayReading("5.6 W"))
        #expect(read(.display, OverlaySample(displayHz: 120)) == OverlayReading("120 Hz"))
        #expect(read(.uptime, OverlaySample(uptimeSecs: 291_600)) == OverlayReading("3d 9h"))
        #expect(read(.uptime, OverlaySample(uptimeSecs: 4_380)) == OverlayReading("1h 13m"))
    }
}

@Suite struct OverlayPlacementTests {
    /// A 1800×1169 screen with a 38pt menu bar and a 82pt Dock.
    private let visible = CGRect(x: 0, y: 82, width: 1800, height: 1049)
    private let size = CGSize(width: 160, height: 200)

    private func frame(_ corner: OverlayCorner, _ dx: Int = 12, _ dy: Int = 12) -> CGRect {
        OverlayPlacement.frame(size: size, corner: corner, offsetX: dx, offsetY: dy, in: visible)
    }

    @Test func eachCornerSitsInsideTheVisibleFrame() {
        #expect(frame(.topRight).origin == CGPoint(x: 1628, y: 919))
        #expect(frame(.topLeft).origin == CGPoint(x: 12, y: 919))
        #expect(frame(.bottomLeft).origin == CGPoint(x: 12, y: 94))
        #expect(frame(.bottomRight).origin == CGPoint(x: 1628, y: 94))
    }

    /// A secondary screen left of the main one has a negative origin.
    @Test func followsAScreenWithANegativeOrigin() {
        let left = CGRect(x: -2560, y: 0, width: 2560, height: 1415)
        let placed = OverlayPlacement.frame(size: size, corner: .topLeft, offsetX: 12, offsetY: 12, in: left)
        #expect(placed.origin == CGPoint(x: -2548, y: 1203))
    }

    @Test func anOversizedOffsetIsPulledBackOnScreen() {
        let placed = frame(.topRight, 5000, 5000)
        #expect(visible.contains(placed))
        #expect(placed.origin == CGPoint(x: 0, y: 82))
    }
}

@Suite struct OverlayScreenChoiceTests {
    private let names = ["Built-in Retina Display", "LG UltraFine"]
    private let frames = [CGRect(x: 0, y: 0, width: 1800, height: 1169), CGRect(x: 1800, y: 0, width: 2560, height: 1440)]

    private func index(_ display: OverlayDisplay, mouse: CGPoint = .zero) -> Int {
        OverlayPlacement.screenIndex(for: display, names: names, frames: frames, mouse: mouse)
    }

    @Test func mainIsTheMenuBarScreen() {
        #expect(index(.main) == 0)
    }

    @Test func namedScreenIsFoundAndFallsBackWhenUnplugged() {
        #expect(index(.named("LG UltraFine")) == 1)
        #expect(index(.named("Studio Display")) == 0)
    }

    @Test func mouseFollowsThePointerIncludingTheTopEdge() {
        #expect(index(.mouse, mouse: CGPoint(x: 2000, y: 500)) == 1)
        #expect(index(.mouse, mouse: CGPoint(x: 100, y: 1169)) == 0)
        #expect(index(.mouse, mouse: CGPoint(x: -5000, y: 0)) == 0)
    }
}

@Suite struct OverlayMetricEditingTests {
    @Test func switchingOnAppendsAndOffRemoves() {
        #expect(OverlayMetric.toggling(.power, in: [.cpu, .gpu]) == [.cpu, .gpu, .power])
        #expect(OverlayMetric.toggling(.cpu, in: [.cpu, .gpu]) == [.gpu])
    }

    @Test func movingStopsAtTheEnds() {
        #expect(OverlayMetric.moving(.gpu, by: -1, in: [.cpu, .gpu, .fan]) == [.gpu, .cpu, .fan])
        #expect(OverlayMetric.moving(.gpu, by: 1, in: [.cpu, .gpu, .fan]) == [.cpu, .fan, .gpu])
        #expect(OverlayMetric.moving(.cpu, by: -1, in: [.cpu, .gpu]) == [.cpu, .gpu])
        #expect(OverlayMetric.moving(.power, by: 1, in: [.cpu, .gpu]) == [.cpu, .gpu])
    }

    /// A reordered list must come back in the new order after a relaunch.
    @Test func reorderedListRoundTrips() {
        let reordered = OverlayMetric.moving(.network, by: -1, in: OverlayMetric.defaultMetrics)
        #expect(OverlayMetric.parse(csv: OverlayMetric.csv(reordered)) == reordered)
    }
}

@Suite struct OverlayAnchorTests {
    private let visible = CGRect(x: 0, y: 82, width: 1800, height: 1049)
    private let size = CGSize(width: 160, height: 200)

    /// Placing and then reading back the anchor must be the identity for
    /// every corner, or a drag-and-release would nudge the panel.
    @Test func anchorInvertsPlacement() {
        for corner in OverlayCorner.allCases {
            let frame = OverlayPlacement.frame(size: size, corner: corner, offsetX: 30, offsetY: 45, in: visible)
            let anchor = OverlayPlacement.anchor(of: frame, in: visible)
            #expect(anchor.corner == corner)
            #expect(anchor.offsetX == 30 && anchor.offsetY == 45, "\(corner)")
        }
    }

    /// Dragged partly past the edge: offsets never go negative.
    @Test func offsetsNeverGoNegative() {
        let frame = CGRect(x: -20, y: 1000, width: 160, height: 200)
        let anchor = OverlayPlacement.anchor(of: frame, in: visible)
        #expect(anchor.corner == .topLeft)
        #expect(anchor.offsetX == 0 && anchor.offsetY == 0)
    }
}

@Suite struct OverlayRefreshTests {
    @Test func batteryDoublesTheIntervalOnlyWhenAskedTo() {
        var configuration = OverlayConfiguration.defaults
        #expect(configuration.effectiveRefreshMillis(onBattery: false) == 1000)
        #expect(configuration.effectiveRefreshMillis(onBattery: true) == 2000)
        configuration.slowOnBattery = false
        #expect(configuration.effectiveRefreshMillis(onBattery: true) == 1000)
    }
}

@Suite struct OverlayHotkeyTests {
    @Test func roundTripsThroughItsStoredForm() {
        let hotkey = OverlayHotkey(keyCode: 122, modifiers: OverlayHotkey.control | OverlayHotkey.shift, key: "F1")
        #expect(OverlayHotkey(rawValue: hotkey.rawValue) == hotkey)
        #expect(OverlayHotkey(rawValue: OverlayHotkey.suggested.rawValue) == .suggested)
    }

    /// A colon is a key of its own on most layouts; only the first two
    /// separators split the stored form.
    @Test func aColonKeySurvives() {
        let hotkey = OverlayHotkey(keyCode: 41, modifiers: OverlayHotkey.command | OverlayHotkey.option, key: ":")
        #expect(OverlayHotkey(rawValue: hotkey.rawValue) == hotkey)
    }

    @Test func rejectsMalformedOrShiftOnlyShortcuts() {
        #expect(OverlayHotkey(rawValue: "") == nil)
        #expect(OverlayHotkey(rawValue: "31:abc:O") == nil)
        #expect(OverlayHotkey(rawValue: "31:\(OverlayHotkey.shift):O") == nil)
    }

    @Test func printsModifiersInMenuOrder() {
        let all = OverlayHotkey.command | OverlayHotkey.shift | OverlayHotkey.option | OverlayHotkey.control
        #expect(OverlayHotkey(keyCode: 31, modifiers: all, key: "O").displayString == "⌃⌥⇧⌘O")
        #expect(OverlayHotkey.suggested.displayString == "⌃⌥⌘O")
    }
}
