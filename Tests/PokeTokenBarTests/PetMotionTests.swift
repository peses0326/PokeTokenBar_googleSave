import XCTest
@testable import PokeTokenBar

@MainActor
final class PetMotionTests: XCTestCase {
    private typealias S = PetMotionSchedule

    // MARK: Gate

    func testMotionsRunOnlyWhenEveryGateIsOpen() {
        let all = Set(PetMotion.allCases)
        XCTAssertEqual(S.activeMotions(autoMotion: true, enabled: all, motionAllowed: true, bobbing: false),
                       PetMotion.allCases)
        XCTAssertEqual(S.activeMotions(autoMotion: false, enabled: all, motionAllowed: true, bobbing: false), [],
                       "auto motion switched off")
        XCTAssertEqual(S.activeMotions(autoMotion: true, enabled: all, motionAllowed: false, bobbing: false), [],
                       "Reduce Motion / Low Power")
        XCTAssertEqual(S.activeMotions(autoMotion: true, enabled: all, motionAllowed: true, bobbing: true), [],
                       "the agent bob owns the sprite")
        XCTAssertEqual(S.activeMotions(autoMotion: true, enabled: [], motionAllowed: true, bobbing: false), [],
                       "every checkbox cleared")
    }

    func testOnlyCheckedMotionsAreOfferedInAStableOrder() {
        XCTAssertEqual(S.activeMotions(autoMotion: true, enabled: [.sway, .hop], motionAllowed: true, bobbing: false),
                       [.hop, .sway])
    }

    // MARK: Picking and timing

    func testPickAvoidsAnImmediateRepeatWhenThereIsAChoice() {
        for index in 0..<20 {
            XCTAssertNotEqual(S.pick(from: [.hop, .wiggle], previous: .hop, index: index), .hop)
        }
        XCTAssertEqual(S.pick(from: [.hop], previous: .hop, index: 3), .hop, "a single motion may repeat")
        XCTAssertNil(S.pick(from: [], previous: nil, index: 0))
        XCTAssertNotNil(S.pick(from: [.hop, .sway], previous: nil, index: -7), "negative random index stays in range")
    }

    func testDelayStaysInsideTheRangeSoTheLoopMostlySleeps() {
        XCTAssertEqual(S.nextDelay(unit: 0), S.delayRange.lowerBound)
        XCTAssertEqual(S.nextDelay(unit: 1), S.delayRange.upperBound)
        XCTAssertEqual(S.nextDelay(unit: 5), S.delayRange.upperBound, "clamped")
        XCTAssertGreaterThanOrEqual(S.delayRange.lowerBound, 5, "idle motion must not become a busy loop")
    }

    func testHopNeverRisesAboveTheEmptyRowsOverTheSprite() {
        XCTAssertEqual(S.hopHeight(petSize: 100, visibleTop: 40), 12, "12% of the pet when there is room")
        XCTAssertEqual(S.hopHeight(petSize: 100, visibleTop: 5), 5, "a tall sprite hops only as far as its headroom")
        XCTAssertEqual(S.hopHeight(petSize: 100, visibleTop: 0), 0, "touching the top: no hop")
        XCTAssertEqual(S.hopHeight(petSize: 100, visibleTop: nil), 0, "unknown headroom: no hop")
    }

    // MARK: Persistence

    func testEnabledSetDefaultsToAllAndRoundTrips() throws {
        let suite = "PetMotionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        XCTAssertTrue(store.floatingPetAutoMotion)
        XCTAssertEqual(store.floatingPetMotions, Set(PetMotion.allCases))

        store.floatingPetAutoMotion = false
        store.floatingPetMotions = [.wiggle]
        let reloaded = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        XCTAssertFalse(reloaded.floatingPetAutoMotion)
        XCTAssertEqual(reloaded.floatingPetMotions, [.wiggle])

        store.floatingPetMotions = []
        XCTAssertEqual(UsageStore(providers: [], autoRefresh: false, defaults: defaults).floatingPetMotions, [],
                       "clearing every box must not fall back to all")
    }

    func testUnknownStoredMotionsAreDropped() {
        XCTAssertEqual(PetMotion.decode(["hop", "moonwalk"]), [.hop])
        XCTAssertEqual(PetMotion.decode(nil), Set(PetMotion.allCases))
    }

    // MARK: Controller wiring

    /// The bobbing branch through the real controller: a working agent stops idle motion, idle resumes it.
    func testAgentWorkPausesIdleMotionAndIdleResumesIt() throws {
        let suite = "PetMotionWiring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        let controller = FloatingPetController(store: store, companion: companion, defaults: defaults,
                                               motionOverride: true)
        controller.setDisplayAwake(false)
        store.floatingPetEnabled = true

        func send(_ state: String) throws {
            let url = try XCTUnwrap(URL(string: "poketokenbar://agent?state=\(state)"))
            controller.handleAgentEvent(try XCTUnwrap(AgentActivityEvent(url: url)))
        }

        try send("idle")
        XCTAssertEqual(controller.idleMotions, PetMotion.allCases)
        try send("working")
        XCTAssertTrue(controller.isBobbing)
        XCTAssertEqual(controller.idleMotions, [], "no idle motion on top of the agent bob")
        try send("idle")
        XCTAssertEqual(controller.idleMotions, PetMotion.allCases)
    }
}
