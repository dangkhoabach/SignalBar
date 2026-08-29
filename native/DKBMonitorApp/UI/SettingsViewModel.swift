import DKBMonitorCore
import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    static let shared = SettingsViewModel(
        repo: AppDatabase.shared.map { SettingsRepository(dbQueue: $0.dbQueue) }
    )

    private let repo: SettingsRepository?
    private var isLoaded = false

    var settings: AppSettings = .defaults {
        didSet {
            guard isLoaded, oldValue != settings else { return }
            try? repo?.update(settings)
        }
    }

    init(repo: SettingsRepository?) {
        self.repo = repo
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        settings = (try? repo?.load()) ?? .defaults
        isLoaded = true
    }
}
