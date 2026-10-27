import AppKit
import Foundation
import UniformTypeIdentifiers

/// The save/open panel plumbing behind every "Export…"/"Import…" menu item.
///
/// The Domains list and the Servers list each had their own copy: configure
/// a panel for JSON, bail on cancel, do the work, and phrase the failure as
/// "Export failed: …". Only the middle step differs between them, so that's
/// the only part left to the caller.
///
/// Both functions return the message to show on failure, or `nil` when the
/// work succeeded *or* the user cancelled — a cancelled panel is a decision,
/// not an error, and shouldn't raise an alert.
@MainActor
enum JSONDocumentPanel {
    /// Asks where to save, then writes whatever `makeData` produces.
    static func export(suggestedName: String, makeData: () throws -> Data) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try makeData().write(to: url)
            return nil
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    /// Asks for a file, then hands its bytes to `apply`, which is where the
    /// caller decodes, stores, and reports whatever it imported.
    static func `import`(apply: (Data) throws -> Void) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try apply(try Data(contentsOf: url))
            return nil
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }
}
