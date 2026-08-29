import SwiftUI
import DKBMonitorCore

@main
struct DKBMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let windowDelegate = HideInsteadOfCloseDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
        }
        .windowResizability(.contentSize)

        Settings {
            Text("Settings — Phase 12")
                .padding()
                .frame(width: 400, height: 200)
        }

        // Empty for now per Phase 1 scope — real stats/menu content lands in Phase 7.
        MenuBarExtra("DKB Monitor", systemImage: "waveform.path.ecg") {
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
