import SignalBarCore
import SwiftUI

/// The menu bar panel, laid out as in the author's other menu bar apps: a
/// header with the domains summary, the domains that are down, and a footer
/// with the app-level actions.
struct MenuBarPanelView: View {
    static let width: CGFloat = 360
    /// Past this many, the rest of the domains that are down are counted, not listed.
    static let listedLimit = 8

    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        // The panel is not part of a SwiftUI scene, so the in-app language is
        // applied here rather than inherited.
        MenuBarPanelContent()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .frame(width: Self.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                StatusBarController.shared.fitPanel(height: height)
            }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MenuBarPanelContent: View {
    @Bindable private var model = MenuBarStatusViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            domains
            Divider()
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            Text(verbatim: "SignalBar").font(.headline)
            Spacer()
            Label {
                Text(model.domainsLabel)
            } icon: {
                Image(systemName: model.hasDownTargets ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(model.hasDownTargets ? .red : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var domains: some View {
        if model.downTargets.isEmpty {
            Label(model.hasTargets ? "Every domain is up." : "No domains yet.",
                  systemImage: model.hasTargets ? "checkmark.circle" : "globe")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 2) {
                ForEach(model.downTargets.prefix(MenuBarPanelView.listedLimit)) { overview in
                    DownTargetRow(overview: overview)
                }
                if model.downTargets.count > MenuBarPanelView.listedLimit {
                    Text("And \(model.downTargets.count - MenuBarPanelView.listedLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Show SignalBar", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
            footerButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
            footerButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
            Spacer()
            footerButton("Quit SignalBar", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A domain that is down: its name and address, opening its page in the
/// main window.
private struct DownTargetRow: View {
    let overview: TargetOverview
    @State private var isHovered = false

    var body: some View {
        Button {
            StatusBarController.shared.closePanel()
            AppNavigationState.shared.handleNotificationRoute("/targets/\(overview.id)")
            WindowPresenter.showMainWindow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: overview.target.name).lineLimit(1)
                    Text(verbatim: overview.latestCheck?.errorMessage ?? overview.target.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
