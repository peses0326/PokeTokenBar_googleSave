import XCTest
@testable import PokeTokenBar

@MainActor
final class RemoteUsageTests: XCTestCase {
    private let server = "22222222-2222-4222-8222-222222222222"

    private func usage(_ days: [String: Int], device: String? = nil) -> RemoteDeviceUsage {
        RemoteDeviceUsage(device: device ?? server, deviceName: "parkes-server", updatedAt: nil,
                          days: days.mapValues { ["claude": $0] })
    }

    // MARK: Crediting rules

    func testFirstSightSeedsThenCreditsOnlyNewUsage() {
        var ledger: [String: RemoteUsageLedger] = [:]
        let history = ["2026-11-12": 500, "2026-11-13": 300]
        XCTAssertEqual(RemoteUsageCredit.apply([usage(history)], ledger: &ledger, todayDate: "2026-11-13"), 0,
                       "usage from before the link is not paid out")
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-12": 500, "2026-11-13": 450])], ledger: &ledger,
                                               todayDate: "2026-11-13"), 150)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-12": 500, "2026-11-13": 450])], ledger: &ledger,
                                               todayDate: "2026-11-13"), 0, "the same totals never pay twice")
    }

    func testUsageLaterOnTheDayTheDeviceWasSeenWithNothingCounts() {
        var ledger: [String: RemoteUsageLedger] = [:]
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-12": 500])], ledger: &ledger, todayDate: "2026-11-13"), 0)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-12": 500, "2026-11-13": 80])], ledger: &ledger,
                                               todayDate: "2026-11-13"), 80)
    }

    func testNewDaysCountInFullAndOldDaysAppearingLateDoNot() {
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(["2026-11-13": 10])], ledger: &ledger, todayDate: "2026-11-13")
        let next = usage(["2026-11-12": 999, "2026-11-13": 10, "2026-11-14": 70])
        XCTAssertEqual(RemoteUsageCredit.apply([next], ledger: &ledger, todayDate: "2026-11-14"), 70,
                       "11-12 is before the link (seeded), 11-14 is new")
    }

    func testLateUploadForYesterdayCountsAndDaysOutsideTheWindowAreIgnored() {
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(["2026-11-13": 100])], ledger: &ledger, todayDate: "2026-11-13")
        // The server's last pre-midnight upload arrives after this Mac's date changed.
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 160])], ledger: &ledger, todayDate: "2026-11-14"), 60)
        // Days fall out of the window and the ledger, and stay ignored when the file still lists them.
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 160])], ledger: &ledger, todayDate: "2026-11-20"), 0)
        XCTAssertNil(ledger[server]?.claimed["2026-11-13"])
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 900])], ledger: &ledger, todayDate: "2026-11-20"), 0)
    }

    func testALowerTotalRebasesInsteadOfGoingNegative() {
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(["2026-11-13": 100])], ledger: &ledger, todayDate: "2026-11-13")
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 40])], ledger: &ledger, todayDate: "2026-11-13"), 0)
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 90])], ledger: &ledger, todayDate: "2026-11-13"), 50)
    }

    func testDevicesAreCreditedIndependently() {
        let other = "33333333-3333-4333-8333-333333333333"
        var ledger: [String: RemoteUsageLedger] = [:]
        _ = RemoteUsageCredit.apply([usage(["2026-11-13": 0]), usage(["2026-11-13": 0], device: other)],
                                    ledger: &ledger, todayDate: "2026-11-13")
        XCTAssertEqual(RemoteUsageCredit.apply([usage(["2026-11-13": 5]), usage(["2026-11-13": 7], device: other)],
                                               ledger: &ledger, todayDate: "2026-11-13"), 12)
    }

    func testHostileFilesAreDropped() {
        let bad = [
            RemoteDeviceUsage(device: "not-a-uuid", deviceName: "x", updatedAt: nil, days: ["2026-11-13": ["claude": 1]]),
            RemoteDeviceUsage(device: server, deviceName: "x", updatedAt: nil, days: ["2026-11-13": ["claude": -5]]),
            RemoteDeviceUsage(device: server, deviceName: "x", updatedAt: nil, days: ["13/11/2026": ["claude": 1]]),
            RemoteDeviceUsage(device: server, deviceName: "x", updatedAt: nil,
                              days: ["2026-11-13": ["claude": RemoteUsageCredit.maxDayTokens + 1]]),
        ]
        XCTAssertTrue(RemoteUsageCredit.validated(bad).isEmpty)
        XCTAssertEqual(RemoteUsageCredit.validated([usage(["2026-11-13": 1]), usage(["2026-11-13": 2])]).count, 1,
                       "one device id cannot be counted twice")
    }

    // MARK: Save integration

    func testImportingAnOlderSaveKeepsTheHigherLedger() {
        var current = CompanionState()
        current.remoteUsageLedger = [server: RemoteUsageLedger(seededThrough: "2026-11-10", claimed: ["2026-11-13": 900])]
        var imported = CompanionState()
        imported.remoteUsageLedger = [server: RemoteUsageLedger(seededThrough: "2026-11-10", claimed: ["2026-11-13": 100])]
        let rebased = SaveTransfer.rebasedForThisDevice(imported, current: current, todayTokensByProvider: [:],
                                                        todayDate: "2026-11-13", hasUsageData: false)
        XCTAssertEqual(rebased.remoteUsageLedger[server]?.claimed["2026-11-13"], 900)
    }

    func testLedgerSurvivesTheSaveRoundTripAndIsPartOfTheSyncedDigest() throws {
        var state = CompanionState()
        let before = try GoogleCloudSync.gameplayDigest(state)
        state.remoteUsageLedger = [server: RemoteUsageLedger(seededThrough: "2026-11-13", claimed: ["2026-11-13": 5])]
        XCTAssertNotEqual(try GoogleCloudSync.gameplayDigest(state), before, "a credit must make the save upload")
        let decoded = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.remoteUsageLedger, state.remoteUsageLedger)
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
        XCTAssertEqual(companion.creditRemoteUsage([usage(["2026-11-13": 100])], todayDate: "2026-11-13"), 0)
        XCTAssertEqual(companion.creditRemoteUsage([usage(["2026-11-13": 350])], todayDate: "2026-11-13"), 250)
        XCTAssertEqual(companion.state.usedSinceInstall, 250)
        XCTAssertEqual(companion.state.eggUsage, 250, "an egg incubates with remote usage too")
        let saved = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.remoteUsageLedger[server]?.claimed["2026-11-13"], 350)
    }

    func testNothingIsCreditedBeforeTheInstallBaseline() throws {
        let name = "ptb-remote-usage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(CompanionState()).write(to: file)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(companion.creditRemoteUsage([usage(["2026-11-13": 100])], todayDate: "2026-11-13"), 0)
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
                    {"status":"ok","devices":[{"device":"\(server)","deviceName":"parkes-server",
                    "updatedAt":"x","days":{"\(today)":{"claude":\(tokens)}}}]}
                    """.utf8)
                }
                if let index = arguments.firstIndex(of: "--request"), arguments.contains("exchange") {
                    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) as? [String: Any]
                    let ledger = ((payload?["state"] as? [String: Any])?["remoteUsageLedger"] as? [String: Any])?[server] as? [String: Any]
                    uploadedLedgers.append((ledger?["claimed"] as? [String: Int])?[today] ?? -1)
                }
                return Data("{\"status\":\"uploaded\",\"heads\":[]}".utf8)
            })
        await sync.synchronize(companion: companion, usage: usageStore)
        tokens = 400
        await sync.synchronize(companion: companion, usage: usageStore)
        XCTAssertEqual(companion.state.usedSinceInstall, 300)
        XCTAssertEqual(uploadedLedgers, [100, 400], "the credit is in the save that is uploaded")
        XCTAssertEqual(sync.remoteDevices.map(\.deviceName), ["parkes-server"])

        listFails = true
        await sync.synchronize(companion: companion, usage: usageStore)
        XCTAssertNil(sync.errorMessage, "usage files are a bonus; the save still syncs")
        XCTAssertEqual(uploadedLedgers.count, 3)
    }
}
