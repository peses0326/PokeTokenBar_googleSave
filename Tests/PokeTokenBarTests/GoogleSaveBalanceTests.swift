import XCTest
@testable import PokeTokenBar

/// PokeTokenBar_gs-only balance: 40% cheaper growth and eggs that never repeat a hatched line.
/// Both are off in tests by default (no `PTBGoogleSaveVersion` in the test bundle), so these tests
/// turn them on explicitly.

private enum GSBalanceTestError: Error { case offline }

/// Three single-stage lines; the REST fallback is offline so only the weighted path runs.
private struct ThreeLineProvider: PokeProviding {
    static let ids = [10, 20, 30]
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["en": "Mon \(baseSpeciesID)", "ko": "몬 \(baseSpeciesID)"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        Self.ids.map { BaseSpecies(id: $0, captureRate: 255) }
    }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { throw GSBalanceTestError.offline }
}

@MainActor
final class GoogleSaveBalanceTests: XCTestCase {
    // MARK: Growth cost

    func testGSGrowthFactorCutsEveryStageBy40Percent() {
        let gs = PokemonBalance.gsGrowthCostFactor
        XCTAssertEqual(gs, 0.6)
        XCTAssertEqual(PokemonBalance.graduationTotal(.common, factor: gs), 450_000_000)
        XCTAssertEqual(PokemonBalance.graduationTotal(.uncommon, factor: gs), 1_125_000_000)
        XCTAssertEqual(PokemonBalance.graduationTotal(.rare, factor: gs), 1_800_000_000)
        XCTAssertEqual(PokemonBalance.graduationTotal(.legendary, factor: gs), 3_600_000_000)
        for rarity in [Rarity.common, .uncommon, .rare, .legendary] {
            for forms in 1...3 {
                for stage in 0..<forms {
                    let original = PokemonBalance.phaseThreshold(rarity: rarity, totalForms: forms, stageIndex: stage, factor: 1)
                    let gsCost = PokemonBalance.phaseThreshold(rarity: rarity, totalForms: forms, stageIndex: stage, factor: gs)
                    XCTAssertEqual(Double(gsCost), Double(original) * 0.6, accuracy: 1, "\(rarity) \(forms) forms, stage \(stage)")
                }
            }
        }
        // Easy (10%): a 100M step becomes 60M — rare line of three, second stage.
        XCTAssertEqual(PokemonBalance.scaled(PokemonBalance.phaseThreshold(rarity: .rare, totalForms: 3, stageIndex: 1, factor: 1), by: 0.1), 100_000_000)
        XCTAssertEqual(PokemonBalance.scaled(PokemonBalance.phaseThreshold(rarity: .rare, totalForms: 3, stageIndex: 1, factor: gs), by: 0.1), 60_000_000)
    }

    func testOriginalBuildAndTestsKeepTheUpstreamTotals() {
        XCTAssertEqual(PokemonBalance.growthCostFactor, 1, "the test bundle is not the _gs build")
        XCTAssertEqual(PokemonBalance.graduationTotal(.common), 750_000_000)
        XCTAssertEqual(FreshEgg.price(guaranteeing: .rare), FreshEgg.price * 4, "tier egg prices follow the ratio, not the factor")
    }

    // MARK: Hatching

    private func store(_ state: CompanionState, seed: UInt64, skipsAppearedLines: Bool) throws -> CompanionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gs-balance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: url)
        let suite = "gs-balance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(1.0, forKey: "growthDifficulty")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return CompanionStore(provider: ThreeLineProvider(), clock: { now }, fileURL: url, rng: SeededRNG(seed: seed),
                              dittoDisguiseRollingEnabled: false, skipsAppearedLines: skipsAppearedLines,
                              defaults: defaults)
    }

    private func entry(_ id: Int, released: Bool) -> DexEntry {
        var e = DexEntry(baseID: id, finalID: id, chainOrder: [id], rarity: .common, caughtAt: Date(), isShiny: false,
                         nature: .brave, names: [id: ["en": "Mon \(id)"]])
        if released { e.releasedAt = Date() }
        return e
    }

    private func readyEgg(dex: [DexEntry]) -> CompanionState {
        var state = CompanionState()
        state.eggUsage = PokemonBalance.eggHatchThreshold
        state.dex = dex
        state.collectedFinals = Set(dex.filter { $0.releasedAt == nil }.map { "\($0.baseID):\($0.finalID)" })
        return state
    }

    func testEggNeverHatchesALineThatAlreadyHatched() async throws {
        // 10 graduated, 20 released: only 30 is left, whatever the roll.
        for seed: UInt64 in [1, 2, 3, 7, 42, 99, 128, 999] {
            let s = try store(readyEgg(dex: [entry(10, released: false), entry(20, released: true)]),
                              seed: seed, skipsAppearedLines: true)
            await s.hatchIfNeeded()
            XCTAssertEqual(s.currentSpeciesID, 30, "seed \(seed)")
        }
    }

    func testRepeatsReturnOnlyWhenEveryLineHasHatched() async throws {
        var hatched = Set<Int>()
        for seed: UInt64 in [1, 2, 3, 7, 42, 99, 128, 999] {
            let s = try store(readyEgg(dex: ThreeLineProvider.ids.map { entry($0, released: false) }),
                              seed: seed, skipsAppearedLines: true)
            await s.hatchIfNeeded()
            hatched.insert(try XCTUnwrap(s.currentSpeciesID, "the egg must not get stuck"))
        }
        XCTAssertTrue(hatched.isSubset(of: Set(ThreeLineProvider.ids)))
    }

    func testOriginalSelectionStillAllowsRepeats() async throws {
        // Without the gs rule, collected lines keep half weight and do come back.
        var hatched = Set<Int>()
        for seed: UInt64 in 1...40 {
            let s = try store(readyEgg(dex: [entry(10, released: false), entry(20, released: true)]),
                              seed: seed, skipsAppearedLines: false)
            await s.hatchIfNeeded()
            hatched.insert(try XCTUnwrap(s.currentSpeciesID))
        }
        XCTAssertTrue(hatched.contains(10) || hatched.contains(20))
    }
}
