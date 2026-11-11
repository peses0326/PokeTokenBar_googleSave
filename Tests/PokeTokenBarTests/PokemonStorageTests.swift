import XCTest
@testable import PokeTokenBar

private func storageLine() -> EvoLine {
    let tree = EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])])
    var names: [Int: [String: String]] = [:]
    for id in [1, 2, 3] { names[id] = ["en": "P\(id)", "ko": "포\(id)"] }
    return EvoLine(baseID: 1, tree: tree, rarity: .common, names: names)
}

/// 보관(storage): buying an egg stores the current Pokémon instead of releasing it, stored Pokémon
/// can be raised again, and an egg in progress is paused rather than lost or duplicated.
@MainActor
final class PokemonStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(_ state: CompanionState) throws -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID()).json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: StubProvider(value: storageLine()), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: 7))
    }

    private func mon(base: Int = 1, path: [Int] = [1, 2], stage: Int = 1, used: Int = 123_000_000,
                     shiny: Bool = false) -> MonState {
        MonState(baseID: base, pathIDs: path, plannedPathIDs: [1, 2, 3], stageIndex: stage, usedAtStage: used,
                 rarity: .common, totalForms: 3, isShiny: shiny, nature: .adamant)
    }

    private func wallet(_ s: inout CompanionState) {
        s.installBaselineSet = true
        s.usedSinceInstall = 20_000_000_000
    }

    func testBuyingAnEggStoresTheWholeIndividual() throws {
        var state = CompanionState(); wallet(&state)
        state.active = mon()
        let s = try store(state)

        XCTAssertTrue(s.buyEgg(nil))
        let entry = try XCTUnwrap(s.storedEntries.first)
        XCTAssertEqual(entry.stored?.stageIndex, 1)
        XCTAssertEqual(entry.stored?.usedAtStage, 123_000_000)
        XCTAssertEqual(entry.stored?.nature, .adamant)
        XCTAssertNil(entry.releasedAt)
        XCTAssertEqual(entry.chainOrder, [1, 2], "only reached stages count as owned")
        let cell = try XCTUnwrap(s.dexSpecies.first { $0.id == 2 })
        XCTAssertTrue(cell.isStored, "the stored individual's current form carries the badge")
        XCTAssertFalse(try XCTUnwrap(s.dexSpecies.first { $0.id == 1 }).isStored, "not the earlier stage")
        XCTAssertEqual(s.storedEntries(for: cell).map(\.id), [entry.id])
    }

    func testRaisingSwapsWithTheCurrentPokemon() throws {
        var state = CompanionState(); wallet(&state)
        let kept = mon(used: 7)
        state.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common, caughtAt: now, stored: kept)]
        state.active = mon(base: 1, path: [1], stage: 0, used: 99, shiny: true)
        let s = try store(state)
        let storedID = s.state.dex[0].id

        XCTAssertTrue(s.raiseStored(storedID))
        XCTAssertEqual(s.state.active?.usedAtStage, 7)
        XCTAssertEqual(s.state.active?.currentID, 2)
        XCTAssertNil(s.state.pausedEgg, "no egg was in progress")
        XCTAssertEqual(s.storedEntries.count, 1)
        XCTAssertEqual(s.storedEntries.first?.stored?.usedAtStage, 99, "the previous Pokémon went into storage")
        XCTAssertTrue(s.storedEntries.first?.isShiny ?? false)
        XCTAssertFalse(s.state.dex.contains { $0.id == storedID }, "the raised one leaves storage")
    }

    /// Trigger branch: raising from the egg state must pause the egg — progress, paid guarantee,
    /// pre-rolled species and prayers — and storing the Pokémon again must resume exactly that egg.
    func testRaisingFromAnEggPausesItAndStoringResumesIt() throws {
        var state = CompanionState(); wallet(&state)
        state.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common, caughtAt: now, stored: mon())]
        state.eggUsage = 3_000_000
        state.eggTier = .rare
        state.pendingHatchID = 1
        state.eggPrayers = PrayerRecord(count: 4)
        let s = try store(state)

        XCTAssertTrue(s.raiseStored(s.state.dex[0].id))
        XCTAssertEqual(s.state.pausedEgg, PausedEgg(usage: 3_000_000, tier: .rare, pendingHatchID: 1,
                                                    pendingForm: nil, prayers: PrayerRecord(count: 4)))
        XCTAssertEqual(s.state.eggUsage, 0)
        XCTAssertNil(s.state.eggTier)
        XCTAssertNil(s.state.pendingHatchID)
        XCTAssertFalse(s.canBuyEgg(nil), "a second egg would overwrite the paid, paused one")
        XCTAssertTrue(s.canStoreActive)

        XCTAssertTrue(s.storeActive())
        XCTAssertNil(s.state.active)
        XCTAssertNil(s.state.pausedEgg)
        XCTAssertEqual(s.state.eggUsage, 3_000_000)
        XCTAssertEqual(s.state.eggTier, .rare)
        XCTAssertEqual(s.state.pendingHatchID, 1)
        XCTAssertEqual(s.state.eggPrayers?.count, 4)
        XCTAssertEqual(s.storedEntries.count, 1)
    }

    /// Storing without a paused egg would hand out a free egg — the shop egg's whole price.
    func testStoringAloneIsRefusedWithoutAPausedEgg() throws {
        var state = CompanionState(); wallet(&state)
        state.active = mon()
        let s = try store(state)
        XCTAssertFalse(s.canStoreActive)
        XCTAssertFalse(s.storeActive())
        XCTAssertNotNil(s.state.active)
        XCTAssertTrue(s.storedEntries.isEmpty)
    }

    func testGraduationResumesAPausedEggInsteadOfAFreeOne() async throws {
        var state = CompanionState(); wallet(&state)
        state.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common, caughtAt: now,
                              stored: mon(used: 0))]
        state.eggUsage = 4_000_000
        state.eggTier = .uncommon
        let s = try store(state)
        XCTAssertTrue(s.raiseStored(s.state.dex[0].id))
        let deadline = Date().addingTimeInterval(2)
        while s.currentLine == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(s.currentLine, "the raised Pokémon's line loads after the swap")
        for stage in 1..<3 {
            s.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: stage))
        }
        XCTAssertNil(s.state.active, "graduated")
        XCTAssertNil(s.state.pausedEgg)
        XCTAssertEqual(s.state.eggUsage, 4_000_000, "the paid egg resumes instead of a free one")
        XCTAssertEqual(s.state.eggTier, .uncommon)
    }

    func testReleasingFromStorageKeepsTheDexRecord() throws {
        var state = CompanionState()
        state.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common, caughtAt: now, stored: mon())]
        let s = try store(state)
        let id = s.state.dex[0].id

        XCTAssertTrue(s.releaseStored(id))
        XCTAssertNil(s.state.dex[0].stored)
        XCTAssertEqual(s.state.dex[0].releasedAt, now)
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 2 }, "the species stays in the Pokédex")
        XCTAssertFalse(s.dexSpecies.contains { $0.isStored })
        XCTAssertFalse(s.raiseStored(id), "a released individual cannot come back")
    }

    func testStorageSurvivesSaveAndReload() throws {
        var state = CompanionState(); wallet(&state)
        state.active = mon()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID()).json")
        try JSONEncoder().encode(state).write(to: url)
        let s = CompanionStore(provider: StubProvider(value: storageLine()), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertTrue(s.buyEgg(nil))
        let reloaded = CompanionStore(provider: StubProvider(value: storageLine()), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.storedEntries.first?.stored?.usedAtStage, 123_000_000)
    }

    /// A damaged stored individual must not drop the dex entry; it degrades to a released record.
    func testDamagedStoredIndividualDegradesToAReleasedRecord() throws {
        let json = #"{"baseID":1,"finalID":2,"chainOrder":[1,2],"rarity":"common","caughtAt":0,"stored":{"baseID":1,"pathIDs":[]}}"#
        let entry = try JSONDecoder().decode(DexEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.stored)
        XCTAssertTrue(entry.isReleased)
    }

    func testSanitizeResumesAnOrphanedPausedEgg() {
        var state = CompanionState()
        state.pausedEgg = PausedEgg(usage: 9, tier: .legendary, pendingHatchID: 5, pendingForm: nil, prayers: nil)
        let clean = SaveTransfer.sanitized(state)
        XCTAssertNil(clean.pausedEgg)
        XCTAssertEqual(clean.eggUsage, 9)
        XCTAssertEqual(clean.pendingHatchID, 5)
        XCTAssertNil(clean.eggTier, "an unsatisfiable guarantee is dropped like the live one")

        var withActive = CompanionState()
        withActive.active = mon()
        withActive.pausedEgg = PausedEgg(usage: 9, tier: nil, pendingHatchID: nil, pendingForm: nil, prayers: nil)
        withActive.dex = [DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common, caughtAt: nil,
                                   stored: mon(stage: 9, used: -5))]
        let kept = SaveTransfer.sanitized(withActive)
        XCTAssertEqual(kept.pausedEgg?.usage, 9)
        XCTAssertEqual(kept.dex[0].stored?.stageIndex, 1, "stored stage is clamped like the active one")
        XCTAssertEqual(kept.dex[0].stored?.usedAtStage, 0)
    }
}

/// Eggs never hatch a line that is in storage unless the hatch is shiny.
@MainActor
final class StoredLineHatchTests: XCTestCase {
    private func store(seed: UInt64, storedBase: Int?) throws -> CompanionStore {
        var state = CompanionState()
        if let storedBase {
            let mon = MonState(baseID: storedBase, pathIDs: [storedBase], stageIndex: 0, usedAtStage: 0,
                               rarity: .common, totalForms: 3)
            state.dex = [DexEntry(baseID: storedBase, finalID: storedBase, chainOrder: [storedBase],
                                  rarity: .common, caughtAt: nil, stored: mon)]
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-hatch-\(UUID()).json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: StubProvider(value: storageLine()), clock: { Date() },
                              fileURL: url, rng: SeededRNG(seed: seed))
    }

    func testStoredLineOnlyHatchesAsShiny() async throws {
        var shinyHatches = 0, discarded = 0
        for seed in UInt64(1)...640 {
            let s = try store(seed: seed, storedBase: 1)
            await s.hatch(baseID: 1)
            if let active = s.state.active {
                XCTAssertTrue(active.isShiny, "seed \(seed): a stored line hatched as a normal Pokémon")
                shinyHatches += 1
            } else {
                XCTAssertNil(s.state.pendingHatchID, "the rejected pre-roll is dropped so the next roll is fresh")
                discarded += 1
            }
        }
        XCTAssertGreaterThan(shinyHatches, 0, "a shiny of a stored line must still be possible")
        XCTAssertGreaterThan(discarded, shinyHatches * 20, "normal hatches of a stored line are rejected")
    }

    /// Lines without a stored individual hatch exactly as before (same RNG sequence, normal odds).
    func testOtherLinesAreUnaffected() async throws {
        for seed in UInt64(1)...64 {
            let plain = try store(seed: seed, storedBase: nil)
            let other = try store(seed: seed, storedBase: 99)
            await plain.hatch(baseID: 1)
            await other.hatch(baseID: 1)
            XCTAssertNotNil(other.state.active)
            XCTAssertEqual(other.state.active?.isShiny, plain.state.active?.isShiny)
            XCTAssertEqual(other.state.active?.nature, plain.state.active?.nature)
        }
    }

    func testReleasingFromStorageLiftsTheRestriction() async throws {
        let s = try store(seed: 3, storedBase: 1)
        XCTAssertTrue(s.releaseStored(s.state.dex[0].id))
        XCTAssertTrue(s.storedBaseIDs.isEmpty)
        await s.hatch(baseID: 1)
        XCTAssertNotNil(s.state.active)
    }
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

    func testStoredIndividualKeepsItsLook() throws {
        var state = CompanionState()
        state.installBaselineSet = true
        state.usedSinceInstall = 10_000_000_000
        var mon = MonState(baseID: 1, pathIDs: [1, 2], plannedPathIDs: [1, 2, 3], stageIndex: 1, usedAtStage: 0,
                           rarity: .common, totalForms: 3)
        mon.appearanceID = 1
        state.active = mon
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID()).json")
        try JSONEncoder().encode(state).write(to: url)
        let s = CompanionStore(provider: StubProvider(value: storageLine()), clock: { Date() }, fileURL: url,
                               rng: SeededRNG(seed: 7))
        XCTAssertTrue(s.buyEgg(nil))
        XCTAssertTrue(s.raiseStored(try XCTUnwrap(s.storedEntries.first).id))
        XCTAssertEqual(s.displaySpeciesID, 1)
    }
}
