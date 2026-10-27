import AppKit
import GRDB
import Testing
@testable import SignalBarCore
@testable import SignalBar

private struct OnBatterySampler: OverlaySampling {
    func snapshotOverlay(metrics: Set<OverlayMetric>) async -> OverlaySample {
        OverlaySample(cpuPercent: 10, batteryPercent: 60, batteryCharging: false)
    }
}

private struct FixedSampler: OverlaySampling {
    func snapshotOverlay(metrics: Set<OverlayMetric>) async -> OverlaySample {
        OverlaySample(cpuPercent: 42, cpuTempCelsius: 55, gpuPercent: 7, ramUsedMB: 12_000, ramTotalMB: 18_432)
    }
}

/// Drives the real panel from an in-memory settings database, so nothing
/// here touches the user's saved settings.
@MainActor
@Suite(.serialized) struct OverlayWindowControllerTests {
    private func makeController(sampler: OverlaySampling = FixedSampler()) throws -> (OverlayWindowController, SettingsViewModel) {
        let db = try AppDatabase(inMemory: DatabaseQueue())
        let settings = SettingsViewModel(repo: SettingsRepository(dbQueue: db.dbQueue))
        return (OverlayWindowController(settings: settings, sampler: sampler), settings)
    }

    /// The controller applies changes on the next main-actor turn, and the
    /// panel grows once the first sample's rows lay out.
    private func settle(until condition: () -> Bool = { true }) async {
        try? await Task.sleep(for: .milliseconds(150))
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func disabledByDefaultCreatesNoWindow() throws {
        let (controller, _) = try makeController()
        controller.start()
        #expect(controller.panel == nil)
        #expect(!controller.model.isRunning)
    }

    @Test func enablingShowsAClickThroughPanelInTheChosenCorner() async throws {
        let (controller, settings) = try makeController()
        controller.start()
        settings.settings.overlay.enabled = true
        // Four rows at ~16 pt each, plus padding.
        await settle { (controller.panel?.frame.height ?? 0) > 60 }

        let panel = try #require(controller.panel)
        #expect(panel.isVisible)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(controller.model.isRunning)

        let visible = try #require(NSScreen.screens.first).visibleFrame
        #expect(panel.frame.width > 0 && panel.frame.height > 0)
        #expect(abs(panel.frame.maxX - (visible.maxX - 12)) < 1, "\(panel.frame) in \(visible)")
        #expect(abs(panel.frame.maxY - (visible.maxY - 12)) < 1, "\(panel.frame) in \(visible)")

        settings.settings.overlay.corner = .bottomLeft
        await settle()
        #expect(abs(panel.frame.minX - (visible.minX + 12)) < 1)
        #expect(abs(panel.frame.minY - (visible.minY + 12)) < 1)

        settings.settings.overlay.showOverFullScreen = false
        await settle()
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))

        settings.settings.overlay.enabled = false
        await settle()
        #expect(!panel.isVisible)
        #expect(!controller.model.isRunning)
    }

    /// Unlocking lets the panel take the mouse; dropping it saves the
    /// nearest corner and offsets; hiding always locks it again.
    @Test func droppingTheUnlockedPanelSavesTheNearestCorner() async throws {
        let (controller, settings) = try makeController()
        controller.start()
        settings.settings.overlay.enabled = true
        await settle { (controller.panel?.frame.height ?? 0) > 60 }
        let panel = try #require(controller.panel)

        controller.setUnlocked(true)
        #expect(!panel.ignoresMouseEvents)
        #expect(controller.model.isUnlocked)

        let visible = try #require(panel.screen ?? NSScreen.screens.first).visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.minX + 40, y: visible.minY + 30))
        panel.onDragEnded?()
        #expect(settings.settings.overlay.corner == .bottomLeft)
        #expect(settings.settings.overlay.offsetX == 40)
        #expect(settings.settings.overlay.offsetY == 30)

        settings.settings.overlay.enabled = false
        await settle()
        #expect(!controller.model.isUnlocked)
        #expect(panel.ignoresMouseEvents)
    }

    @Test func sparklinesSwitchHistoryRecording() async throws {
        let (controller, settings) = try makeController()
        controller.start()
        settings.settings.overlay.enabled = true
        settings.settings.overlay.sparklines = true
        await settle { controller.model.histories[.cpu] != nil }
        #expect(controller.model.histories[.cpu] != nil)
        settings.settings.overlay.sparklines = false
        await settle()
        #expect(controller.model.histories.isEmpty)
        settings.settings.overlay.enabled = false
        await settle()
    }

    /// Every pause reason stops the loop on its own, and sampling only
    /// comes back once the last one clears.
    @Test func pausesWhileAnyReasonHolds() async throws {
        let (controller, settings) = try makeController()
        controller.start()
        settings.settings.overlay.enabled = true
        await settle()
        #expect(controller.model.isRunning)

        controller.setPaused(true, for: .displaysAsleep)
        controller.setPaused(true, for: .sessionInactive)
        #expect(!controller.model.isRunning)
        controller.setPaused(false, for: .displaysAsleep)
        #expect(!controller.model.isRunning)
        controller.setPaused(false, for: .sessionInactive)
        #expect(controller.model.isRunning)

        settings.settings.overlay.enabled = false
        await settle()
    }

    @Test func runningOnBatteryDoublesTheInterval() async throws {
        let (controller, settings) = try makeController(sampler: OnBatterySampler())
        controller.start()
        settings.settings.overlay.enabled = true
        await settle { controller.model.intervalMillis == 2000 }
        #expect(controller.model.intervalMillis == 2000)

        settings.settings.overlay.slowOnBattery = false
        await settle { controller.model.intervalMillis == 1000 }
        #expect(controller.model.intervalMillis == 1000)

        settings.settings.overlay.enabled = false
        await settle()
    }

    /// Toggling reuses the one panel: the window list must not grow.
    @Test func togglingRepeatedlyKeepsOneWindow() async throws {
        let (controller, settings) = try makeController()
        controller.start()
        settings.settings.overlay.enabled = true
        await settle()
        let windowsAfterFirstShow = NSApp.windows.count
        for _ in 0..<50 {
            settings.settings.overlay.enabled.toggle()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        settings.settings.overlay.enabled = false
        await settle()
        #expect(NSApp.windows.count == windowsAfterFirstShow)
        #expect(!controller.model.isRunning)
    }
}
