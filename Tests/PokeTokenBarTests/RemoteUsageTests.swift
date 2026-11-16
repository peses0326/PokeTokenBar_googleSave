import XCTest
@testable import PokeTokenBar

@MainActor
final class RemoteUsageTests: XCTestCase {
    private let server = "22222222-2222-4222-8222-222222222222"

    private func usage(total: Int?, today: Int = 0, device: String? = nil) -> RemoteDeviceUsage {
        RemoteDeviceUsage(device: device ?? server, deviceName: "my-server", updatedAt: nil,
                          days: ["2026-11-13": ["claude": today]], total: total.map { ["claude": $0] })
    }

    // MARK: Crediting rules

    func testFirstSightSeedsThenCreditsOnlyNewUsage() {
        var ledger: [String: RemoteUsageLedger] = [:]
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 5_000)], ledger: &ledger), 0,
                       "usage from before the link is not paid out")
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 5_150)], ledger: &ledger), 150)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 5_150)], ledger: &ledger), 0, "the same total never pays twice")
    }

    func testAnyGapBetweenSyncsIsCountedInFull() {
        // No Mac opened for weeks while the server kept working: there is no date window to fall out of.
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(total: 1_000)], ledger: &ledger)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 9_001_000)], ledger: &ledger), 9_000_000)
    }

    func testALowerTotalRebasesInsteadOfGoingNegative() {
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(total: 1_000)], ledger: &ledger)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 40)], ledger: &ledger), 0, "collector reset")
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 90)], ledger: &ledger), 50)
    }

    func testDevicesAreCreditedIndependently() {
        let other = "33333333-3333-4333-8333-333333333333"
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(total: 0), usage(total: 0, device: other)], ledger: &ledger)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: 5), usage(total: 7, device: other)], ledger: &ledger), 12)
    }

    func testAFileWithoutATotalIsShownButNotCredited() {
        var ledger: [String: RemoteUsageLedger] = [:]
        XCTAssertEqual(RemoteUsageCredit.apply([usage(total: nil, today: 500)], ledger: &ledger), 0)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(RemoteUsageCredit.validated([usage(total: nil, today: 500)]).count, 1)
    }

    func testHostileFilesAreDropped() {
        let bad = [
            RemoteDeviceUsage(device: "not-a-uuid", deviceName: "x", days: [:], total: ["claude": 1]),
            RemoteDeviceUsage(device: server, deviceName: "x", days: [:], total: ["claude": -5]),
            RemoteDeviceUsage(device: server, deviceName: "x", days: ["13/11/2026": ["claude": 1]], total: nil),
            RemoteDeviceUsage(device: server, deviceName: "x", days: [:], total: ["claude": RemoteUsageCredit.maxTotalTokens + 1]),
        ]
        XCTAssertTrue(RemoteUsageCredit.validated(bad).isEmpty)
        XCTAssertEqual(RemoteUsageCredit.validated([usage(total: 1), usage(total: 2)]).count, 1,
                       "one device id cannot be counted twice")
    }

    // MARK: Save integration

    func testImportingAnOlderSaveKeepsTheHigherLedger() {
        var current = CompanionState()
        current.remoteUsageLedger = [server: RemoteUsageLedger(claimedTotal: 900)]
        var imported = CompanionState()
        imported.remoteUsageLedger = [server: RemoteUsageLedger(claimedTotal: 100)]
        let rebased = SaveTransfer.rebasedForThisDevice(imported, current: current, todayTokensByProvider: [:],
                                                        todayDate: "2026-11-13", hasUsageData: false)
        XCTAssertEqual(rebased.remoteUsageLedger[server]?.claimedTotal, 900)
    }

    func testLedgerSurvivesTheSaveRoundTripAndIsPartOfTheSyncedDigest() throws {
        var state = CompanionState()
        let before = try GoogleCloudSync.gameplayDigest(state)
        state.remoteUsageLedger = [server: RemoteUsageLedger(claimedTotal: 5)]
        XCTAssertNotEqual(try GoogleCloudSync.gameplayDigest(state), before, "a credit must make the save upload")
        let decoded = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.remoteUsageLedger, state.remoteUsageLedger)
    }

    func testAPreviousDayWindowLedgerIsReseededNotCrashed() throws {
        // Saves written by the first remote-usage build kept per-day claims. They decode to an empty
        // ledger, so the device is seeded again on the next sync instead of breaking the save.
        let json = #"{"installBaselineSet":true,"usedSinceInstall":7,"remoteUsageLedger":{"\#(server)":{"seededThrough":"2026-11-16","claimed":{"2026-11-16":5}}}}"#
        let state = try JSONDecoder().decode(CompanionState.self, from: Data(json.utf8))
        XCTAssertEqual(state.usedSinceInstall, 7)
        XCTAssertTrue(state.remoteUsageLedger.isEmpty)
    }

    func testStoreGrowsTheCompanionAndPersistsTheLedger() throws {
        let name = "ptb-remote-usage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.installBaselineSet = true
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(companion.creditRemoteUsage([usage(total: 100)]), 0)
        XCTAssertEqual(companion.creditRemoteUsage([usage(total: 350)]), 250)
        XCTAssertEqual(companion.state.usedSinceInstall, 250)
        XCTAssertEqual(companion.state.eggUsage, 250, "an egg incubates with remote usage too")
        let saved = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.remoteUsageLedger[server]?.claimedTotal, 350)
    }

    func testNothingIsCreditedBeforeTheInstallBaseline() throws {
        let name = "ptb-remote-usage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(CompanionState()).write(to: file)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(companion.creditRemoteUsage([usage(total: 100)]), 0)
        XCTAssertTrue(companion.state.remoteUsageLedger.isEmpty)
    }

    // MARK: Sync wiring

    func testSyncCreditsOtherDevicesBeforeUploadingAndAFailedListDoesNotBlockTheSave() async throws {
        let name = "ptb-remote-sync-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "googleSyncEnabled")
        var state = CompanionState()
        state.installBaselineSet = true
        let file = directory.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        let usageStore = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let today = LocalUsageReader.todayKey()
        let server = self.server
        nonisolated(unsafe) var tokens = 100
        nonisolated(unsafe) var listFails = false
        nonisolated(unsafe) var uploadedLedgers: [Int] = []
        let sync = GoogleCloudSync(directory: directory.appendingPathComponent("google-sync"), defaults: defaults,
            runner: { arguments, _ in
                if arguments.contains("usage-list") {
                    if listFails { throw CloudSyncError.message("offline") }
                    return Data("""
                    {"status":"ok","devices":[{"device":"\(server)","deviceName":"my-server",
                    "updatedAt":"x","days":{"\(today)":{"claude":\(tokens)}},"total":{"claude":\(tokens)}}]}
                    """.utf8)
                }
                if let index = arguments.firstIndex(of: "--request"), arguments.contains("exchange") {
                    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) as? [String: Any]
                    let ledger = ((payload?["state"] as? [String: Any])?["remoteUsageLedger"] as? [String: Any])?[server] as? [String: Any]
                    uploadedLedgers.append(ledger?["claimedTotal"] as? Int ?? -1)
                }
                return Data("{\"status\":\"uploaded\",\"heads\":[]}".utf8)
            })
        await sync.synchronize(companion: companion, usage: usageStore)
        tokens = 400
        await sync.synchronize(companion: companion, usage: usageStore)
        XCTAssertEqual(companion.state.usedSinceInstall, 300)
        XCTAssertEqual(uploadedLedgers, [100, 400], "the credit is in the save that is uploaded")
        XCTAssertEqual(sync.remoteDevices.map(\.deviceName), ["my-server"])

        listFails = true
        await sync.synchronize(companion: companion, usage: usageStore)
        XCTAssertNil(sync.errorMessage, "usage files are a bonus; the save still syncs")
        XCTAssertEqual(uploadedLedgers.count, 3)
    }
}
