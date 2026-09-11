import Foundation
import GRDB
import Testing
@testable import DKBMonitorCore

@Suite struct RemoteCommandExecutorTests {
    private func makeServer() throws -> (RemoteServerRepository, RemoteServer) {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore())
        let server = try repo.add(NewRemoteServerInput(
            name: "Prod", host: "127.0.0.1", port: 1, username: "deploy", credential: .password("s3cr3t")
        ))
        return (repo, server)
    }

    @Test func rejectsAnActionWhoseServiceIsNotAllowlisted() async throws {
        let (repo, server) = try makeServer()
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("nginx")) {
            try await executor.execute(.serviceRestart(name: "nginx"), on: server)
        }
    }

    @Test func rejectsAServiceNameWithShellMetacharactersEvenIfSomehowAllowlisted() async throws {
        let (repo, server) = try makeServer()
        try repo.addAllowlistEntry(serverId: server.id!, kind: .service, value: "nginx; rm -rf /")
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.invalidAllowlistValue("nginx; rm -rf /")) {
            try await executor.execute(.serviceRestart(name: "nginx; rm -rf /"), on: server)
        }
    }

    @Test func isValidServiceNameAcceptsTypicalSystemdUnitNames() {
        #expect(RemoteCommandExecutor.isValidServiceName("nginx"))
        #expect(RemoteCommandExecutor.isValidServiceName("php8.3-fpm"))
        #expect(RemoteCommandExecutor.isValidServiceName("myapp@1.service"))
        #expect(!RemoteCommandExecutor.isValidServiceName(""))
        #expect(!RemoteCommandExecutor.isValidServiceName("nginx; rm -rf /"))
        #expect(!RemoteCommandExecutor.isValidServiceName("nginx && reboot"))
        #expect(!RemoteCommandExecutor.isValidServiceName("nginx\ndocker"))
    }

    @Test func isValidConfigPathRestrictsToEtcNginx() {
        #expect(RemoteCommandExecutor.isValidConfigPath("/etc/nginx/sites-available/default"))
        #expect(!RemoteCommandExecutor.isValidConfigPath("/etc/passwd"))
        #expect(!RemoteCommandExecutor.isValidConfigPath("/etc/nginx/../passwd"))
        #expect(!RemoteCommandExecutor.isValidConfigPath("/etc/nginx/sites-available/default; rm -rf /"))
    }

    @Test func nginxTestRequiresAtLeastOneAllowlistedConfigPath() async throws {
        let (repo, server) = try makeServer()
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("nginx (no config path allowlisted)")) {
            try await executor.execute(.nginxTest, on: server)
        }
    }

    @Test func nginxReloadRequiresNginxInTheServiceAllowlist() async throws {
        let (repo, server) = try makeServer()
        try repo.addAllowlistEntry(serverId: server.id!, kind: .nginxConfigPath, value: "/etc/nginx/sites-available/default")
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("nginx (not in the service allowlist)")) {
            try await executor.execute(.nginxReload, on: server)
        }
    }

    @Test func readConfigRejectsAnUnallowlistedPath() async throws {
        let (repo, server) = try makeServer()
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("/etc/nginx/sites-available/default")) {
            _ = try await executor.readConfig(path: "/etc/nginx/sites-available/default", on: server)
        }
    }

    @Test func writeConfigRejectsAPathOutsideEtcNginx() async throws {
        let (repo, server) = try makeServer()
        try repo.addAllowlistEntry(serverId: server.id!, kind: .nginxConfigPath, value: "/etc/passwd")
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.invalidAllowlistValue("/etc/passwd")) {
            try await executor.writeConfig(path: "/etc/passwd", content: "evil", on: server)
        }
    }

    @Test func tailLogRejectsAnUnallowlistedPath() async throws {
        let (repo, server) = try makeServer()
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("/var/log/nginx/error.log")) {
            try await executor.execute(.tailLog(path: "/var/log/nginx/error.log", lines: 100), on: server)
        }
    }

    @Test func tailLogRejectsPathTraversal() async throws {
        let (repo, server) = try makeServer()
        try repo.addAllowlistEntry(serverId: server.id!, kind: .logPath, value: "/var/log/../etc/passwd")
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.invalidAllowlistValue("/var/log/../etc/passwd")) {
            try await executor.execute(.tailLog(path: "/var/log/../etc/passwd", lines: 100), on: server)
        }
    }

    @Test func clampedTailLinesStaysWithinBounds() {
        #expect(RemoteCommandExecutor.clampedTailLines(0) == 1)
        #expect(RemoteCommandExecutor.clampedTailLines(100) == 100)
        #expect(RemoteCommandExecutor.clampedTailLines(1_000_000) == 2000)
    }

    @Test func parsesDiskUsageFromDfOutput() {
        let output = "Filesystem      Size  Used Avail Use% Mounted on\n/dev/sda1        20G  8.0G   11G  43% /\n"
        let parsed = RemoteCommandExecutor.parseDiskUsage(output)
        #expect(parsed == RemoteDiskUsage(size: "20G", used: "8.0G", available: "11G", usePercent: "43%"))
    }

    @Test func parsesMemoryUsageFromFreeOutput() {
        let output = """
              total        used        free      shared  buff/cache   available
        Mem:           7955        1234         123          45        6598        6500
        Swap:             0           0           0
        """
        let parsed = RemoteCommandExecutor.parseMemoryUsage(output)
        #expect(parsed == RemoteMemoryUsage(totalMB: 7955, usedMB: 1234, freeMB: 123, availableMB: 6500))
    }

    @Test func parsesUptimeLoadAverages() {
        let parsed = RemoteCommandExecutor.parseUptime(" 17:10:00 up 3 days,  2:14,  1 user,  load average: 0.08, 0.03, 0.01")
        #expect(parsed.loadAverages == [0.08, 0.03, 0.01])
    }

    @Test func uptimeWithoutLoadAverageStillReturnsRawText() {
        let parsed = RemoteCommandExecutor.parseUptime("unexpected format")
        #expect(parsed.raw == "unexpected format")
        #expect(parsed.loadAverages.isEmpty)
    }
}
