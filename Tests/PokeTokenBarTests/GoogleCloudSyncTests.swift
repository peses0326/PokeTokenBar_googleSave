import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

@MainActor
final class GoogleCloudSyncTests: XCTestCase {
    private func fixture(_ body: @MainActor (URL, UserDefaults, CompanionStore, UsageStore) async throws -> Void) async throws {
        let name = "ptb-google-tests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "googleSyncEnabled")
        var state = CompanionState()
        state.installBaselineSet = true
        state.usedSinceInstall = 100
        state.claimedCumulativeTokens = ["server/claude": 90]
        state.language = .en
        let file = directory.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: file)
        let line = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [:])
        let companion = CompanionStore(provider: StubProvider(value: line), fileURL: file,
            rng: SeededRNG(seed: 7), dittoDisguiseRollingEnabled: false, defaults: defaults)
        let usage = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        try await body(directory, defaults, companion, usage)
    }

    func testInitialEmptyOrConflictDoesNotOverwriteExistingProgress() async throws {
        try await fixture { directory, defaults, companion, usage in
            for status in ["empty", "choose", "conflict"] {
                let response = Data("{\"status\":\"\(status)\",\"heads\":[]}".utf8)
                let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                    runner: { _, _ in response })
                await sync.synchronize(companion: companion, usage: usage)
                XCTAssertEqual(sync.status, status)
                XCTAssertEqual(companion.state.usedSinceInstall, 100)
                XCTAssertEqual(companion.state.claimedCumulativeTokens["server/claude"], 90)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud-usage.json").path))
            }
        }
    }

    func testConnectUsesAppConfigWithoutAUserFilePickerAndDoesNotUploadProgress() async throws {
        try await fixture { directory, defaults, companion, usage in
            defaults.set(false, forKey: "googleSyncEnabled")
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                oauthClient: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com"),
                runner: { arguments, _ in
                    guard arguments.contains("authorize") else { throw CloudSyncError.message("Unexpected upload during login") }
                    return Data("{\"status\":\"connected\",\"account\":{\"sub\":\"test-account\",\"email\":\"test@example.invalid\"}}".utf8)
                })
            await sync.connect()
            XCTAssertTrue(sync.enabled)
            XCTAssertEqual(sync.email, "test@example.invalid")
            XCTAssertEqual(sync.status, "connected")
            XCTAssertEqual(companion.state.usedSinceInstall, 100)
            let unconfigured = GoogleCloudSync(directory: directory.appendingPathComponent("unconfigured"), defaults: defaults,
                oauthClient: nil, runner: { _, _ in throw CloudSyncError.message("Browser must not open") })
            await unconfigured.connect()
            XCTAssertNotNil(unconfigured.errorMessage)
            XCTAssertEqual(companion.state.usedSinceInstall, 100)
        }
    }

    func testCloudImportSharesClaimsAndCreatesBackupBeforeReplacement() async throws {
        try await fixture { directory, defaults, companion, usage in
            var remote = companion.state
            remote.usedSinceInstall = 200
            remote.claimedCumulativeTokens = ["server/claude": 200]
            let save = try SaveTransfer.encode(state: remote, appVersion: "test", deviceName: "Other Mac", now: Date())
            let object = try JSONSerialization.jsonObject(with: save)
            let reply = try JSONSerialization.data(withJSONObject: ["status": "download", "save": object,
                "clock": [UUID().uuidString.lowercased(): 1], "digest": "python-game-digest", "usage": []])
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                runner: { arguments, _ in
                    if arguments.contains("ack") { return Data("{\"status\":\"acknowledged\"}".utf8) }
                    return reply
                })
            await sync.synchronize(companion: companion, usage: usage)
            XCTAssertNil(sync.errorMessage)
            XCTAssertEqual(sync.status, "synced")
            XCTAssertEqual(companion.state.usedSinceInstall, 200)
            XCTAssertEqual(companion.state.claimedCumulativeTokens["server/claude"], 200)
            companion.update(todayTokensByProvider: [:], todayDate: "next-day", monthTotal: 0,
                burnTier: .idle, limitWarning: false, hasUsageData: true, cumulativeTokensBySource: ["server/claude": 200])
            XCTAssertEqual(companion.state.usedSinceInstall, 200)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(files.contains { $0.hasPrefix(SaveTransfer.backupFilePrefix) })
            let disk = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: directory.appendingPathComponent("companion-state.json")))
            XCTAssertEqual(disk.claimedCumulativeTokens["server/claude"], 200)
        }
    }

    func testLocalChangesDuringCloudDownloadArePreserved() async throws {
        try await fixture { directory, defaults, companion, usage in
            companion.update(todayTokensByProvider: ["local": 0], todayDate: "day", monthTotal: 0,
                             burnTier: .idle, limitWarning: false, hasUsageData: true)
            var remote = companion.state
            remote.usedSinceInstall = 999
            let object = try JSONSerialization.jsonObject(with: SaveTransfer.encode(state: remote,
                appVersion: "test", deviceName: "Other Mac", now: Date()))
            let reply = try JSONSerialization.data(withJSONObject: ["status": "download", "save": object,
                "clock": [UUID().uuidString.lowercased(): 1], "digest": "digest", "usage": []])
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                runner: { _, _ in
                    await MainActor.run {
                        companion.update(todayTokensByProvider: ["local": 1], todayDate: "day", monthTotal: 0,
                                         burnTier: .idle, limitWarning: false, hasUsageData: true)
                    }
                    return reply
                })
            await sync.synchronize(companion: companion, usage: usage)
            XCTAssertEqual(companion.state.usedSinceInstall, 101)
            XCTAssertEqual(sync.status, "conflict")
            XCTAssertNotNil(sync.errorMessage)
        }
    }

    func testCloudDifficultyImportsWithoutRescalingRemoteCredits() async throws {
        try await fixture { directory, defaults, companion, usage in
            var remote = companion.state
            remote.eggUsage = 1234
            var object = try JSONSerialization.jsonObject(with: SaveTransfer.encode(state: remote,
                appVersion: "test", deviceName: "Other Mac", now: Date())) as! [String: Any]
            object["gameSettings"] = ["growthDifficulty": 0.5, "shopDifficulty": 0.75]
            try companion.applyCloudSave(JSONSerialization.data(withJSONObject: object), usage: usage)
            XCTAssertEqual(companion.growthDifficulty, 0.5)
            XCTAssertEqual(companion.shopDifficulty, 0.75)
            XCTAssertEqual(companion.state.eggUsage, 1234)
            XCTAssertEqual(defaults.double(forKey: "growthDifficulty"), 0.5)
            object["gameSettings"] = ["growthDifficulty": -1, "shopDifficulty": 1]
            XCTAssertThrowsError(try companion.applyCloudSave(JSONSerialization.data(withJSONObject: object), usage: usage))
            XCTAssertEqual(companion.growthDifficulty, 0.5)
        }
    }

    func testProcessRunnerBoundsOutputAndPreservesSafeHelperErrors() async throws {
        do {
            _ = try await ProcessRunner.runCommand(binary: "/usr/bin/printf", arguments: [String(repeating: "x", count: 100)],
                                                   maximumBytes: 16)
            XCTFail("Expected bounded output rejection")
        } catch {}
        do {
            _ = try await ProcessRunner.runCommand(binary: "/bin/sh", arguments: ["-c", "printf '{\"error\":\"Sign in again\"}' >&2; exit 1"])
            XCTFail("Expected helper failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Sign in again") }
    }

    func testDisconnectRemovesOnlyCloudUsageNotTheGameSave() async throws {
        try await fixture { directory, defaults, companion, usage in
            let cloudFile = directory.appendingPathComponent("cloud-usage.json")
            try Data("{}".utf8).write(to: cloudFile)
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                runner: { _, _ in Data("{\"status\":\"disconnected\"}".utf8) })
            await sync.disconnect()
            XCTAssertFalse(sync.enabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cloudFile.path))
            XCTAssertEqual(companion.state.usedSinceInstall, 100)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("companion-state.json").path))
        }
    }

    func testHelperFailureKeepsProgressAndReportsAnError() async throws {
        try await fixture { directory, defaults, companion, usage in
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                runner: { _, _ in throw CloudSyncError.message("Offline") })
            await sync.synchronize(companion: companion, usage: usage)
            XCTAssertEqual(sync.errorMessage, "Offline")
            XCTAssertEqual(companion.state.usedSinceInstall, 100)
            XCTAssertFalse(sync.busy)
        }
    }

    func testCloudUsageCombinesSourcesWithSeparatePersistentGrowthCounters() async throws {
        try await fixture { directory, defaults, companion, usage in
            func source(_ total: Int) -> [String: Any] {
                ["version": 1, "sourceId": UUID().uuidString.lowercased(), "timezone": TimeZone.current.identifier,
                 "generatedAt": ISO8601DateFormatter().string(from: Date()), "providers": [
                    "claude": ["totalTokens": total, "days": [["date": LocalUsageReader.todayKey(), "input": total,
                        "output": 0, "cacheWrite": 0, "cacheRead": 0]]],
                    "codex": ["totalTokens": 0, "days": []]]]
            }
            let file = directory.appendingPathComponent("cloud-usage.json")
            let sources = [source(100), source(200)]
            try JSONSerialization.data(withJSONObject: ["version": 1, "summaries": sources]).write(to: file)
            let cache = CloudUsageCache(file: file)
            let provider = CloudUsageProvider(cache: cache)
            let daily = try await provider.fetchDaily()
            XCTAssertEqual(daily?.totalTokens, 300)
            XCTAssertEqual(daily?.allGrowthCounters.count, 4)
            let store = UsageStore(providers: [provider], autoRefresh: false, defaults: defaults)
            await store.refresh()
            XCTAssertTrue(store.dailyGrowthTokensByProvider.isEmpty)
            XCTAssertEqual(store.cumulativeGrowthTokensBySource.values.reduce(0, +), 300)
            try JSONSerialization.data(withJSONObject: ["version": 1, "summaries": [sources[0], sources[0]]]).write(to: file, options: .atomic)
            do { _ = try await cache.load(); XCTFail("Duplicate source must not double growth") } catch {}
        }
    }

    func testBundledHelperCanBeLocatedAndInvokedWithoutGoogleCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try await GoogleCloudSync.runHelper(["--state-dir", directory.path, "status"], 15)
        let reply = try JSONDecoder().decode(GoogleCloudSync.Reply.self, from: data)
        XCTAssertEqual(reply.status, "disconnected")
    }

    func testPackagedHelperLookupWorksWithoutTheSwiftBuildDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(GoogleCloudSync.packagedHelper(in: directory))
        let packaged = directory.appendingPathComponent("PokeTokenBar_PokeTokenBar.bundle/CloudSync/google_sync.py")
        try FileManager.default.createDirectory(at: packaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# packaged helper".utf8).write(to: packaged)
        XCTAssertEqual(GoogleCloudSync.packagedHelper(in: directory), packaged)
    }

    func testSettingsSectionRendersWithoutCredentials() async throws {
        try await fixture { directory, defaults, companion, usage in
            defaults.set(false, forKey: "googleSyncEnabled")
            let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
                                      oauthClient: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com"))
            let renderer = ImageRenderer(content: GoogleSyncSettingsView(sync: sync, companion: companion, usage: usage)
                .padding(16).frame(width: 360).background(Color.white).environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(image.size.height, 100)
            if let destination = ProcessInfo.processInfo.environment["PTB_CLOUD_SCREENSHOT_DIR"],
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let folder = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("google-sync-settings.png"))
            }
        }
    }
}
