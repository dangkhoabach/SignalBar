import Foundation
import GRDB
import Testing
@testable import SignalBarCore

@Suite struct TargetPortabilityTests {
    @Test func roundTripsThroughExportAndImport() throws {
        let source = try AppDatabase(inMemory: DatabaseQueue())
        let sourceRepo = TargetRepository(dbQueue: source.dbQueue)
        _ = try sourceRepo.add(NewTargetInput(name: "A", url: "https://a.example", checkDomain: true))
        _ = try sourceRepo.add(NewTargetInput(name: "B", url: "https://b.example", groupTag: "custom"))

        let data = try TargetPortability.export(targets: try sourceRepo.list())

        let destination = try AppDatabase(inMemory: DatabaseQueue())
        let destinationRepo = TargetRepository(dbQueue: destination.dbQueue)
        let imported = try TargetPortability.importInto(destinationRepo, data: data)

        #expect(imported == 2)
        let names = try destinationRepo.list().map(\.name).sorted()
        #expect(names == ["A", "B"])
    }

    @Test func skipsDuplicateURLsRatherThanAborting() throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = TargetRepository(dbQueue: app.dbQueue)
        _ = try repo.add(NewTargetInput(name: "Existing", url: "https://dup.example"))

        let data = try TargetPortability.export(targets: [
            Target(name: "Existing", url: "https://dup.example"),
            Target(name: "New", url: "https://new.example"),
        ])

        let imported = try TargetPortability.importInto(repo, data: data)

        #expect(imported == 1)
        #expect(try repo.list().count == 2)
    }
}
