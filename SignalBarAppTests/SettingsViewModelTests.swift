import SignalBarCore
import GRDB
import Testing
@testable import SignalBar

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

        // Polled rather than a fixed 700 ms: with other main-actor suites
        // running in parallel the debounced write can land a little late.
        for _ in 0..<40 where try repo.load().smtpRecipientEmail.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(try repo.load().smtpRecipientEmail == "abc@example.com")
    }

    /// The regression: quitting cancels the task waiting out the debounce, so
    /// a change made within half a second of Cmd+Q was dropped with nothing
    /// to show it had been. `applicationWillTerminate` flushes instead.
    @Test func flushingWritesAnEditStillInsideTheDebounceWindow() throws {
        let (viewModel, repo) = try makeViewModel()
        viewModel.loadIfNeeded()

        var settings = viewModel.settings
        settings.smtpRecipientEmail = "quit@example.com"
        viewModel.settings = settings

        #expect(try repo.load().smtpRecipientEmail.isEmpty)

        viewModel.flushPendingSave()

        #expect(try repo.load().smtpRecipientEmail == "quit@example.com")
    }

    /// Flushing with nothing pending must not write, so quitting can't
    /// overwrite whatever the debounced task already committed.
    @Test func flushingWithNothingPendingIsANoOp() async throws {
        let (viewModel, repo) = try makeViewModel()
        viewModel.loadIfNeeded()

        var settings = viewModel.settings
        settings.smtpRecipientEmail = "settled@example.com"
        viewModel.settings = settings
        try await Task.sleep(nanoseconds: 700_000_000)

        viewModel.flushPendingSave()

        #expect(try repo.load().smtpRecipientEmail == "settled@example.com")
    }
}
