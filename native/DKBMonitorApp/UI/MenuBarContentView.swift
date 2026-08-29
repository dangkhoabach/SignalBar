import SwiftUI

struct MenuBarContentView: View {
    private var model: MenuBarStatsViewModel { .shared }

    var body: some View {
        Text(model.domainsText)
        Text(model.cpuText)
        Text(model.ramText)
        Text(model.temperatureText)
        Text(model.batteryText)
        Divider()
        Button("Show DKB Monitor") { WindowPresenter.showMainWindow() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
