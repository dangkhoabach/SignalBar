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
        // `addWithoutCredential` (unlike `add`) doesn't seed the default
        // nginx config/log allowlist entries — needed here for a genuinely
        // empty allowlist to assert against.
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let repo = RemoteServerRepository(dbQueue: app.dbQueue, keychain: InMemoryKeychainStore())
        let server = try repo.addWithoutCredential(name: "Prod", host: "127.0.0.1", port: 1, username: "deploy", authMethod: .password)
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
        // Not one of `add`'s default-seeded log paths (see its doc comment)
        // — this needs a path that's genuinely absent from the allowlist.
        let (repo, server) = try makeServer()
        let executor = RemoteCommandExecutor(repo: repo)
        await #expect(throws: RemoteCommandExecutorError.notAllowlisted("/var/log/custom-app/error.log")) {
            try await executor.execute(.tailLog(path: "/var/log/custom-app/error.log", lines: 100), on: server)
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
        #expect(parsed == RemoteMemoryUsage(totalMB: 7955, usedMB: 1234, freeMB: 123, availableMB: 6500, swapTotalMB: 0, swapUsedMB: 0))
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

    @Test func parsesCPUUsageFromTopOutput() throws {
        let output = "%Cpu(s):  2.3 us,  1.2 sy,  0.0 ni, 96.0 id,  0.3 wa,  0.0 hi,  0.1 si,  0.0 st"
        let parsed = try #require(RemoteCommandExecutor.parseCPUUsage(output))
        #expect(abs(parsed.busyPercent - 3.7) < 0.001)
        #expect(abs(parsed.ioWaitPercent - 0.3) < 0.001)
    }

    /// Taken verbatim from a production server whose load average read 0.00
    /// at the same moment: the kernel's iowait counter was stuck, not the
    /// disk. Read as `100 - id` this showed a flat 100% and tripped the CPU
    /// alert; the CPU was doing 1% of work.
    @Test func ioWaitIsNotCountedAsBusy() throws {
        let output = "%Cpu(s):  0.6 us,  0.4 sy,  0.0 ni,  0.0 id, 99.0 wa,  0.0 hi,  0.0 si,  0.0 st"
        let parsed = try #require(RemoteCommandExecutor.parseCPUUsage(output))
        #expect(abs(parsed.busyPercent - 1.0) < 0.001)
        #expect(abs(parsed.ioWaitPercent - 99.0) < 0.001)
    }

    /// `top` drops the space before a three-digit idle figure.
    @Test func aFullyIdleCPUParsesAsZeroBusy() throws {
        let output = "%Cpu(s):  0.0 us,  0.0 sy,  0.0 ni,100.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st"
        let parsed = try #require(RemoteCommandExecutor.parseCPUUsage(output))
        #expect(parsed == RemoteCPUUsage(busyPercent: 0, ioWaitPercent: 0))
    }

    @Test func aMissingIOWaitFieldCountsAsZero() throws {
        let parsed = try #require(RemoteCommandExecutor.parseCPUUsage("Cpu(s): 10.0 us,  5.0 sy, 85.0 id"))
        #expect(abs(parsed.busyPercent - 15.0) < 0.001)
        #expect(parsed.ioWaitPercent == 0)
    }

    @Test func parseCPUUsageFailsOnUnrecognizedOutput() {
        #expect(RemoteCommandExecutor.parseCPUUsage("not top output") == nil)
    }

    @Test func parsesOSInfoFromUnameAndOsRelease() {
        let output = "Linux 5.15.0-91-generic\nPRETTY_NAME=\"Ubuntu 22.04.3 LTS\""
        let parsed = RemoteCommandExecutor.parseOSInfo(output)
        #expect(parsed == RemoteOSInfo(kernel: "Linux 5.15.0-91-generic", prettyName: "Ubuntu 22.04.3 LTS"))
    }

    @Test func parsesOSInfoWithoutOsRelease() {
        let output = "Linux 5.15.0-91-generic"
        let parsed = RemoteCommandExecutor.parseOSInfo(output)
        #expect(parsed == RemoteOSInfo(kernel: "Linux 5.15.0-91-generic", prettyName: nil))
    }

    /// Pins a property the validators already had but only by accident of
    /// which regex API they call: `range(of:options:.regularExpression)`
    /// rejects a trailing newline, while `NSRegularExpression` on the very
    /// same pattern accepts one (ICU anchors `$` before it). A value that
    /// passes validation is interpolated straight into a command, so "cannot
    /// span lines" should be asserted, not inherited.
    @Test func rejectsATrailingNewlineInEveryAllowlistedValue() {
        #expect(!RemoteCommandExecutor.isValidServiceName("nginx\n"))
        #expect(!RemoteCommandExecutor.isValidConfigPath("/etc/nginx/nginx.conf\n"))
        #expect(!RemoteCommandExecutor.isValidLogPath("/var/log/nginx/access.log\n"))
    }

    @Test func rejectsEmbeddedControlCharacters() {
        #expect(!RemoteCommandExecutor.isValidServiceName("ng\u{0}inx"))
        #expect(!RemoteCommandExecutor.isValidLogPath("/var/log/a\rb.log"))
    }

    /// Server log lines carry tokens, session ids and user data. The audit
    /// row still records that the read happened and whether it worked — it
    /// just stops copying the contents into the app's unencrypted database.
    @Test func doesNotPersistLogContentsIntoTheAuditTrail() {
        let read = SSHCommandResult(exitCode: 0, stdout: "Bearer abc123 user@example.com", stderr: "")
        #expect(RemoteCommandExecutor.loggableExcerpt(of: read, for: .tailLog(path: "/var/log/app.log", lines: 100)) == nil)
    }

    /// A failed tail still records why, since that's a diagnostic about the
    /// command rather than the file's contents.
    @Test func stillRecordsWhyATailFailed() {
        let denied = SSHCommandResult(exitCode: 1, stdout: "", stderr: "tail: cannot open '/var/log/app.log'")
        let excerpt = RemoteCommandExecutor.loggableExcerpt(of: denied, for: .tailLog(path: "/var/log/app.log", lines: 100))
        #expect(excerpt?.contains("cannot open") == true)
    }

    /// Every other action keeps logging its output — those are command
    /// results (systemctl status, nginx -t), not file contents.
    @Test func stillRecordsOutputForNonLogActions() {
        let status = SSHCommandResult(exitCode: 0, stdout: "active", stderr: "")
        #expect(RemoteCommandExecutor.loggableExcerpt(of: status, for: .serviceStatus(name: "nginx")) == "active")
    }

    /// The ordinary values must still pass, so the tightening didn't just
    /// reject everything.
    @Test func stillAcceptsOrdinaryValues() {
        #expect(RemoteCommandExecutor.isValidServiceName("nginx"))
        #expect(RemoteCommandExecutor.isValidServiceName("php8.1-fpm"))
        #expect(RemoteCommandExecutor.isValidConfigPath("/etc/nginx/sites-available/default"))
        #expect(RemoteCommandExecutor.isValidLogPath("/var/log/nginx/access.log"))
    }
}
