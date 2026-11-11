import XCTest
@testable import PokeTokenBar

private func storageLine() -> EvoLine {
    let tree = EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])])
    var names: [Int: [String: String]] = [:]
    for id in [1, 2, 3] { names[id] = ["en": "P\(id)", "ko": "포\(id)"] }
    return EvoLine(baseID: 1, tree: tree, rarity: .common, names: names)
}

/// 모습 선택: the raised Pokémon can look like any stage it has reached, never an unreached one.
@MainActor
final class AppearanceTests: XCTestCase {
    private func store(stage: Int, appearance: Int? = nil) throws -> CompanionStore {
        var state = CompanionState()
        var mon = MonState(baseID: 1, pathIDs: Array([1, 2, 3].prefix(stage + 1)), plannedPathIDs: [1, 2, 3],
                           stageIndex: stage, usedAtStage: 0, rarity: .common, totalForms: 3)
        mon.appearanceID = appearance
        state.active = mon
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID()).json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: StubProvider(value: storageLine()), clock: { Date() },
                              fileURL: url, rng: SeededRNG(seed: 7))
    }

    func testPickingAnEarlierStageChangesWhatIsDrawnButNotTheSpecies() throws {
        let s = try store(stage: 1)
        XCTAssertEqual(s.displaySpeciesID, 2)
        XCTAssertTrue(s.setAppearance(1))
        XCTAssertEqual(s.displaySpeciesID, 1)
        XCTAssertEqual(s.representativeSubject.speciesID, 1, "menu bar and floating pet follow the look")
        XCTAssertEqual(s.currentSpeciesID, 2, "growth and identity are untouched")
        XCTAssertTrue(s.setAppearance(nil))
        XCTAssertEqual(s.displaySpeciesID, 2)
    }

    func testUnreachedStagesAreLocked() throws {
        let s = try store(stage: 1)
        XCTAssertFalse(s.setAppearance(3), "Venusaur-equivalent is not reached yet")
        XCTAssertEqual(s.displaySpeciesID, 2)
        XCTAssertEqual(s.appearanceChoices.map(\.id), [1, 2, 3])
        XCTAssertEqual(s.appearanceChoices.map(\.unlocked), [true, true, false])
    }

    /// A pinned look survives evolution — the reason to pin it at all.
    func testPinnedLookSurvivesEvolution() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID()).json")
        let s = CompanionStore(provider: StubProvider(value: storageLine()), clock: { Date() },
                               fileURL: url, rng: SeededRNG(seed: 7))
        await s.hatch(baseID: 1)
        s.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: 0))
        XCTAssertEqual(s.currentSpeciesID, 2)
        XCTAssertTrue(s.setAppearance(1))
        s.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: 1))
        XCTAssertEqual(s.currentSpeciesID, 3, "evolved")
        XCTAssertEqual(s.displaySpeciesID, 1, "still drawn as the pinned stage")
        XCTAssertEqual(s.representativeSubject.speciesID, 1)
    }

    /// A hand-edited or stale save cannot show a stage the individual never reached.
    func testInvalidSavedAppearanceFallsBackToTheCurrentStage() throws {
        let s = try store(stage: 1, appearance: 3)
        XCTAssertEqual(s.displaySpeciesID, 2)
    }
}
