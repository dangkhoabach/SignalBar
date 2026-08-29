import SwiftUI

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
        Button("Quit") { NSApp.terminate(nil) }
    }
}
