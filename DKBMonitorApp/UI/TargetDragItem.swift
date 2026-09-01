import CoreTransferable
import UniformTypeIdentifiers

/// Drag payload for cross-group reordering in the Overview list — dropping
/// one onto a group header's `.dropDestination` reassigns that target's
/// `groupTag` (see `OverviewViewModel.moveToGroup`). Only ever transferred
/// within this app's own process, so no Info.plist UTI export is needed.
struct TargetDragItem: Codable, Transferable {
    let id: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dkbMonitorTarget)
    }
}

extension UTType {
    static var dkbMonitorTarget: UTType {
        UTType(exportedAs: "vn.dangkhoabach.dkb-monitor.target")
    }
}
