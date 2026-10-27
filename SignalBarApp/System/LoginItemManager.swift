import Foundation
import ServiceManagement

/// Registers/unregisters this app bundle itself as a Login Item via
/// `SMAppService` — calling the framework directly needs no wrapper library,
/// unlike the Rust version which needed `smappservice_rs` to bind this from
/// outside Swift/ObjC. Ported from an early proof of
/// concept, same logic.
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private var service: SMAppService { .mainApp }

    var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// `true` while macOS requires the user to approve the item in System
    /// Settings before it will actually run (common on first registration).
    var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    /// Only calls `register()` when the service isn't already
    /// Enabled/RequiresApproval — `SMAppService`'s own docs warn that
    /// re-registering an already-registered service isn't guaranteed to be a
    /// safe no-op; doing so produced a duplicate entry in System Settings >
    /// Login Items in the Rust version. Returns whether the item now needs
    /// the user's approval.
    @discardableResult
    func enable() throws -> Bool {
        if service.status != .enabled, service.status != .requiresApproval {
            try service.register()
        }
        let needsApproval = service.status == .requiresApproval
        if needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return needsApproval
    }

    func disable() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }
}
