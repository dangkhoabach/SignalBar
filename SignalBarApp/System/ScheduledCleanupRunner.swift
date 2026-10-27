import SignalBarCore
import Foundation

/// Lets the scheduler run the Cleanup tab's work unattended.
///
/// Thin on purpose: every safety rule already lives elsewhere — the scheduler
/// decides *when* and re-filters *what* through
/// `JunkTarget.scheduledCleaningTargets`, and `JunkCleanerService` owns the
/// deleting, including the one path allowed to bypass the Trash. Re-deriving
/// any of that here would give an unattended run its own second opinion about
/// which files may be destroyed, which is exactly what must not exist.
struct ScheduledCleanupRunner: CleanupRunning {
    private let service: JunkCleanerService

    init(service: JunkCleanerService) {
        self.service = service
    }

    func availableTargets() async -> [JunkTarget] {
        await service.targets
    }

    func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String]) {
        // Measured first, the way the Cleanup tab's own pass does before its
        // Clean button. `clean` reports the freed total from these sizes and
        // never re-walks a target that cleared cleanly — pass none and every
        // run announces "Moved Zero KB", however much actually went. Walked
        // concurrently, off the caller's actor, since a cold cache tree can
        // take seconds each.
        let sizes = await withTaskGroup(of: (String, Int64).self) { group in
            for target in targets {
                group.addTask { (target.path, JunkCleanerService.directorySize(at: target.path)) }
            }
            var sizes: [String: Int64] = [:]
            for await (path, bytes) in group { sizes[path] = bytes }
            return sizes
        }
        let result = await service.clean(paths: Set(targets.map(\.path)), knownSizes: sizes)
        return (result.freedBytes, result.skipped)
    }
}
