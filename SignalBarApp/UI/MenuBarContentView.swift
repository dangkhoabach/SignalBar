import SwiftUI

/// `MenuBarExtra`'s label — a template `Image` (auto-tinted for light/dark
/// menu bars) normally, but swaps to a filled warning triangle in the app's
/// accent-independent system red when any monitored target is down, so a
/// problem is visible at a glance without opening the menu.
struct MenuBarIconView: View {
    @Bindable private var model = MenuBarStatusViewModel.shared

    var body: some View {
        if model.hasDownTargets {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "waveform.path.ecg")
        }
    }
}

/// The menu bar dropdown, rendered as a real SwiftUI panel
/// (`.menuBarExtraStyle(.window)`) rather than a stack of plain menu items.
///
/// A standard `MenuBarExtra` menu can only host menu items; the windowed
/// style hosts a real view, so the domains summary is colour-coded by state.
/// The Mac's own stats moved to EasyDock in 2.2.1.
struct MenuBarContentView: View {
    @Bindable private var model = MenuBarStatusViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("SignalBar").font(.headline)
            Spacer()
            Label {
                Text(model.domainsLabel)
            } icon: {
                Image(systemName: model.hasDownTargets ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(model.hasDownTargets ? .red : .secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            menuButton("Show SignalBar", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
            menuButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
            menuButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
            menuButton("Quit", systemImage: "power") { NSApp.terminate(nil) }
        }
    }

    /// Plain full-width rows with a hover highlight — `.menuBarExtraStyle(.window)`
    /// hosts a real view, so it gets no menu-item styling for free; bordered
    /// buttons here would look nothing like the menu this replaces.
    private func menuButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(.quaternary.opacity(0.001), in: RoundedRectangle(cornerRadius: 5))
    }
}
