import SwiftUI

/// `MenuBarExtra`'s label — a template `Image` (auto-tinted for light/dark
/// menu bars) normally, but swaps to a filled warning triangle in the app's
/// accent-independent system red when any monitored target is down, so a
/// problem is visible at a glance without opening the menu.
struct MenuBarIconView: View {
    @Bindable private var model = MenuBarStatsViewModel.shared

    var body: some View {
        if model.hasDownTargets {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "waveform.path.ecg")
        }
    }
}

struct MenuBarContentView: View {
    private var model: MenuBarStatsViewModel { .shared }

    var body: some View {
        Text(model.domainsLabel)
        Text(model.cpuLabel)
        Text(model.ramLabel)
        Text(model.temperatureLabel)
        Text(model.batteryLabel)
        Divider()
        Button("Show DKB Monitor") { WindowPresenter.showMainWindow() }
        Button("Settings…") { WindowPresenter.showSettings() }
        Button("Check for Updates…") { AppUpdater.checkForUpdates() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
