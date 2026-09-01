import Foundation
import ServiceManagement

/// PoC: registers/unregisters this app bundle itself as a Login Item via
/// SMAppService — calling the framework directly, no wrapper crate needed
/// (the Rust version needed `smappservice-rs` to bind this from outside Swift/ObjC).
///
/// Carries over one important lesson already learned the hard way in the
/// Rust version: SMAppService's own docs warn that re-registering an
/// already-registered service isn't guaranteed to be a safe no-op — doing so
/// produced a duplicate entry in System Settings > Login Items. So: always
/// check `status` before calling `register()` again.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published var status: String = "unknown"

    private var service: SMAppService { SMAppService.mainApp }

    func refreshStatus() {
        status = describe(service.status)
    }

    func enable() {
        guard service.status != .enabled, service.status != .requiresApproval else {
            refreshStatus()
            return
        }
        do {
            try service.register()
        } catch {
            status = "register() failed: \(error.localizedDescription)"
            return
        }
        refreshStatus()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func disable() {
        do {
            try service.unregister()
        } catch {
            status = "unregister() failed: \(error.localizedDescription)"
            return
        }
        refreshStatus()
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status))"
        }
    }
}
