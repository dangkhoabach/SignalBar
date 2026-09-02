import DKBMonitorCore
import GRDB
import Testing
@testable import DKB_Monitor

@MainActor
@Suite struct SettingsViewModelTests {
    private func makeViewModel() throws -> (SettingsViewModel, SettingsRepository) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = SettingsRepository(dbQueue: app.dbQueue)
        return (SettingsViewModel(repo: repo), repo)
    }

    /// Covers the code-review fix: rapid-fire changes (Stepper ticks,
    /// keystrokes) are debounced into a single write instead of hitting
    /// SQLite on every `didSet`.
    @Test func rapidChangesDebounceIntoASingleWrite() async throws {
        let (viewModel, repo) = try makeViewModel()
        viewModel.loadIfNeeded()

        var settings = viewModel.settings
        settings.smtpRecipientEmail = "a@example.com"
        viewModel.settings = settings
        settings.smtpRecipientEmail = "ab@example.com"
        viewModel.settings = settings
        settings.smtpRecipientEmail = "abc@example.com"
        viewModel.settings = settings

        // Nothing persisted yet - still within the debounce window.
        #expect(try repo.load().smtpRecipientEmail.isEmpty)

        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(try repo.load().smtpRecipientEmail == "abc@example.com")
    }
}
