import Foundation
import XCTest
@testable import PokeTokenBar

final class RemoteSummaryTests: XCTestCase {
    func testRealCollectorOutputIsAcceptedByMacReader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let envelope: [String: Any] = ["type": "assistant", "requestId": "req1",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["id": "msg1", "content": "PRIVATE_PROMPT", "usage": [
                "input_tokens": 100, "output_tokens": 20,
                "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40]]]
        var line = try JSONSerialization.data(withJSONObject: envelope)
        line.append(10)
        try line.write(to: logs.appendingPathComponent("one.jsonl"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/remote-usage/collect.py").path,
            "--state-dir", directory.appendingPathComponent("state").path,
            "--claude-root", logs.path, "--timezone", TimeZone.current.identifier]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_PROMPT"))
        let summary = directory.appendingPathComponent("summary.json")
        try data.write(to: summary)
        let provider = RemoteSummaryProvider(kind: .claude, cache: RemoteSummaryCache(file: summary))
        let daily = try await provider.fetchDaily()
        XCTAssertEqual(daily?.totalTokens, 190)
        XCTAssertEqual(daily?.growthCounter?.totalTokens, 190)
    }

    private func write(_ file: URL, total: Int = 190, date: String = LocalUsageReader.todayKey(),
                       source: String = "00000000-0000-4000-8000-000000000001") throws {
        let object: [String: Any] = [
            "version": 1, "sourceId": source, "timezone": TimeZone.current.identifier,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "providers": [
                "claude": ["totalTokens": total, "days": [
                    ["date": date, "input": 100, "output": 20, "cacheWrite": 30, "cacheRead": 40]
                ]],
                "codex": ["totalTokens": 0, "days": []]
            ]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
    }

    func testSummaryPreservesTokenBucketsAndNeverInventsABurnRate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("summary.json")
        try write(file)
        let provider = RemoteSummaryProvider(kind: .claude, cache: RemoteSummaryCache(file: file))
        let daily = try await provider.fetchDaily()
        XCTAssertEqual(daily?.totalTokens, 190)
        XCTAssertEqual(daily?.cacheReadTokens, 40)
        XCTAssertEqual(daily?.growthCounter?.totalTokens, 190)
        XCTAssertFalse(provider.reportsCost)
        let enrichment = await provider.fetchEnrichment()
        XCTAssertTrue(enrichment.periodsOK)
        XCTAssertEqual(enrichment.monthTotal?.totalTokens, 190)
        XCTAssertNil(enrichment.activeBlock)
        XCTAssertNil(enrichment.lastUsage)
    }

    func testMissingMalformedOversizedAndAtomicReplacement() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = RemoteSummaryCache(file: file)
        let missing = try await cache.load()
        XCTAssertNil(missing)
        try write(file)
        let first = try await cache.load()
        XCTAssertEqual(first?.providers["claude"]?.totalTokens, 190)
        try write(file, total: 250)
        let second = try await cache.load()
        XCTAssertEqual(second?.providers["claude"]?.totalTokens, 250)
        for data in [Data("broken".utf8), Data(repeating: 32, count: RemoteSummaryCache.maxBytes + 1)] {
            try data.write(to: file, options: .atomic)
            do { _ = try await cache.load(); XCTFail("Expected invalid summary rejection") } catch {}
        }
        try write(file, total: 1)  // Daily sum exceeds lifetime total.
        do { _ = try await cache.load(); XCTFail("Expected inconsistent totals rejection") } catch {}
        let invalidEnrichment = await RemoteSummaryProvider(kind: .claude, cache: cache).fetchEnrichment()
        XCTAssertFalse(invalidEnrichment.periodsOK)
    }

    func testRejectsInvalidVersionsTimezonesDatesAndTokenCounts() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try write(file)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let cache = RemoteSummaryCache(file: file)
        for mutation in ["version", "source", "timezone", "generated", "providers", "negativeTotal",
                         "negativeDay", "invalidDay", "duplicateDay", "tooManyDays", "lastUsage"] {
            var object = original
            var providers = object["providers"] as! [String: [String: Any]]
            var usage = providers["claude"]!
            var days = usage["days"] as! [[String: Any]]
            switch mutation {
            case "version": object["version"] = 2
            case "source": object["sourceId"] = "invalid"
            case "timezone": object["timezone"] = TimeZone.current.identifier == "UTC" ? "Asia/Seoul" : "UTC"
            case "generated": object["generatedAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            case "providers": providers.removeValue(forKey: "codex")
            case "negativeTotal": usage["totalTokens"] = -1
            case "negativeDay": days[0]["input"] = -1
            case "invalidDay": days[0]["date"] = "2026-99-99"
            case "duplicateDay": days.append(days[0])
            case "tooManyDays": days = Array(repeating: days[0], count: 63)
            case "lastUsage": usage["lastUsage"] = "invalid"
            default: XCTFail("Unknown mutation")
            }
            usage["days"] = days
            providers["claude"] = usage
            object["providers"] = providers
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
            do { _ = try await cache.load(); XCTFail("Accepted invalid \(mutation)") } catch {}
        }
    }

    @MainActor
    func testStoreRoutesCumulativeGrowthSeparatelyFromDailyStatistics() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "remote-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        try write(file)
        let store = UsageStore(providers: [RemoteSummaryProvider(kind: .claude, cache: RemoteSummaryCache(file: file))],
                               autoRefresh: false, defaults: defaults)
        await store.refresh()
        XCTAssertEqual(store.todayTokensByProvider, ["remote_claude": 190])
        XCTAssertTrue(store.dailyGrowthTokensByProvider.isEmpty)
        XCTAssertEqual(store.cumulativeGrowthTokensBySource.values.first, 190)
        store.setProviderEnabled("remote_claude", false)
        await store.refresh()
        XCTAssertTrue(store.cumulativeGrowthTokensBySource.isEmpty)
    }

    @MainActor
    func testCumulativeGrowthSurvivesMidnightRestartRegressionAndNewSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "remote-growth-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let file = dir.appendingPathComponent("companion.json")
        let line = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [:])
        func makeStore() -> CompanionStore {
            CompanionStore(provider: StubProvider(value: line), fileURL: file,
                           rng: SeededRNG(seed: 7), dittoDisguiseRollingEnabled: false, defaults: defaults)
        }
        func update(_ store: CompanionStore, day: String, totals: [String: Int], local: Int = 0) {
            store.update(todayTokensByProvider: ["local": local], todayDate: day, monthTotal: 0,
                         burnTier: .idle, limitWarning: false, hasUsageData: true,
                         cumulativeTokensBySource: totals)
        }
        let first = makeStore()
        // Pure cumulative sources must seed an installation even without any local usage.
        first.update(todayTokensByProvider: [:], todayDate: "d1", monthTotal: 0,
                     burnTier: .idle, limitWarning: false, hasUsageData: true,
                     cumulativeTokensBySource: ["server/claude": 1000])
        XCTAssertTrue(first.state.installBaselineSet)
        update(first, day: "d1", totals: ["server/claude": 1000])
        XCTAssertEqual(first.state.usedSinceInstall, 0)  // No retroactive initial grant.
        update(first, day: "d1", totals: ["server/claude": 1100], local: 10)
        XCTAssertEqual(first.state.usedSinceInstall, 110)
        let restarted = makeStore()
        update(restarted, day: "d2", totals: ["server/claude": 1500])
        XCTAssertEqual(restarted.state.usedSinceInstall, 510)  // Includes delayed yesterday usage.
        update(restarted, day: "d2", totals: [:])  // Temporary missing source.
        update(restarted, day: "d2", totals: ["server/claude": 1500])
        update(restarted, day: "d2", totals: ["server/claude": 1200])  // Older summary.
        update(restarted, day: "d2", totals: ["server/claude": 1600, "new/codex": 5000])
        XCTAssertEqual(restarted.state.usedSinceInstall, 610)
        XCTAssertEqual(restarted.state.claimedCumulativeTokens["server/claude"], 1600)
        let encoded = try JSONEncoder().encode(restarted.state)
        let decoded = try JSONDecoder().decode(CompanionState.self, from: encoded)
        XCTAssertEqual(decoded.claimedCumulativeTokens, restarted.state.claimedCumulativeTokens)
        var imported = CompanionState()
        imported.claimedCumulativeTokens = ["server/claude": 1]
        let rebased = SaveTransfer.rebasedForThisDevice(imported, current: restarted.state,
            todayTokensByProvider: [:], todayDate: "d2", hasUsageData: false)
        XCTAssertEqual(rebased.claimedCumulativeTokens, restarted.state.claimedCumulativeTokens)
    }
}
