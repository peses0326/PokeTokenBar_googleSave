import AppKit
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

    func testHopHeadroomCoversTheJumpAndItsStretch() {
        for size in [48.0, 96, 384] as [CGFloat] {
            let headroom = S.hopHeadroom(petSize: size)
            // The jump plus the 4% take-off stretch must fit, or the top of the sprite clips.
            XCTAssertGreaterThanOrEqual(headroom, S.hopHeight(petSize: size) + size * 0.04, "size \(size)")
        }
    }

    // MARK: Walking

    func testWalkStaysInsideTheRadiusAndTheScreen() {
        let size: CGFloat = 96
        let radius = S.wanderRadius(petSize: size)
        var offset: CGFloat = 0
        for i in 0..<200 {
            offset = S.wanderTarget(current: offset, petSize: size, homeX: 500, visibleMinX: 0, visibleMaxX: 1440,
                                    goRight: i % 3 != 0, unit: Double(i % 7) / 6)
            XCTAssertLessThanOrEqual(abs(offset), radius + 0.001)
        }
        // Home near the right edge: never walks off screen.
        for i in 0..<50 {
            let t = S.wanderTarget(current: 0, petSize: size, homeX: 1440 - size - 10, visibleMinX: 0,
                                   visibleMaxX: 1440, goRight: true, unit: Double(i) / 49)
            XCTAssertLessThanOrEqual(1440 - size - 10 + t + size, 1440)
        }
    }

    func testWalkTurnsAroundAtTheEdgeInsteadOfStandingStill() {
        let size: CGFloat = 96
        let radius = S.wanderRadius(petSize: size)
        let t = S.wanderTarget(current: radius, petSize: size, homeX: 500, visibleMinX: 0, visibleMaxX: 1440,
                               goRight: true, unit: 1)
        XCTAssertLessThan(t, radius, "at the right limit a right step turns into a left step")
    }

    func testWalkFacesTheWayItGoes() {
        XCTAssertTrue(PetIdleMotion.flipsForWalk(goesRight: true, facesBack: false), "front sprites face left")
        XCTAssertFalse(PetIdleMotion.flipsForWalk(goesRight: false, facesBack: false))
        XCTAssertFalse(PetIdleMotion.flipsForWalk(goesRight: true, facesBack: true), "back sprites face right")
        XCTAssertTrue(PetIdleMotion.flipsForWalk(goesRight: false, facesBack: true))
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

    // MARK: Panel during hop and walk

    private func makeController() throws -> (FloatingPetController, UsageStore, UserDefaults, () -> Void) {
        let suite = "PetMotionPanel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        let controller = FloatingPetController(store: store, companion: companion, defaults: defaults,
                                               motionOverride: true)
        controller.setDisplayAwake(false)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        defaults.set(Double(visible.midX), forKey: "floatingPetOriginX")
        defaults.set(Double(visible.minY + 100), forKey: "floatingPetOriginY")
        return (controller, store, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        })
    }

    func testHopGrowsThePanelUpwardWithoutMovingThePet() throws {
        let (controller, store, _, cleanUp) = try makeController()
        defer { cleanUp() }
        let size = CGFloat(store.floatingPetSize)
        let panel = NSPanel(contentRect: NSRect(x: 300, y: 200, width: size, height: size),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        let before = panel.frame
        controller.playIdleMotion(.hop, panel: panel, goRight: true, unit: 0)
        XCTAssertEqual(controller.hopHeadroom, PetMotionSchedule.hopHeadroom(petSize: size))
        XCTAssertEqual(panel.frame.height, size + controller.hopHeadroom, "room above the sprite for the jump")
        XCTAssertNotEqual(panel.frame, before)
        XCTAssertEqual(panel.frame.width, size)
    }

    /// The trigger branch of the persistence guard: frames while walking must not become home,
    /// and a drag during a walk must become home with the offset cleared.
    func testWalkFramesNeverOverwriteHomeButADragDoes() throws {
        let (controller, store, defaults, cleanUp) = try makeController()
        defer { cleanUp() }
        let size = CGFloat(store.floatingPetSize)
        let homeX = defaults.double(forKey: "floatingPetOriginX")
        let homeY = defaults.double(forKey: "floatingPetOriginY")
        let panel = NSPanel(contentRect: NSRect(x: homeX, y: homeY, width: size, height: size),
                            styleMask: [.borderless], backing: .buffered, defer: true)

        controller.playIdleMotion(.walk, panel: panel, goRight: true, unit: 1)
        XCTAssertTrue(controller.isWalking)
        XCTAssertNotEqual(controller.wanderOffsetX, 0)
        controller.panelDidMove(panelOrigin: NSPoint(x: homeX + 37, y: homeY), userDragging: false)
        XCTAssertEqual(defaults.double(forKey: "floatingPetOriginX"), homeX, "a walk frame is not home")

        controller.panelDidMove(panelOrigin: NSPoint(x: homeX + 200, y: homeY), userDragging: true)
        XCTAssertFalse(controller.isWalking)
        XCTAssertEqual(controller.wanderOffsetX, 0)
        XCTAssertEqual(defaults.double(forKey: "floatingPetOriginX"), homeX + 200, "the drop spot is the new home")
    }

    /// After a walk ends, a settings-driven reframe (offset still applied) must save the real home.
    func testReframeAfterAWalkSavesTheRealHome() throws {
        let (controller, store, defaults, cleanUp) = try makeController()
        defer { cleanUp() }
        let size = CGFloat(store.floatingPetSize)
        let homeX = defaults.double(forKey: "floatingPetOriginX")
        let homeY = defaults.double(forKey: "floatingPetOriginY")
        let panel = NSPanel(contentRect: NSRect(x: homeX, y: homeY, width: size, height: size),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        controller.playIdleMotion(.walk, panel: panel, goRight: false, unit: 0.5)
        let offset = controller.wanderOffsetX
        controller.panelDidMove(panelOrigin: NSPoint(x: homeX + offset, y: homeY), userDragging: true)
        // A drag already cleared the offset; replay a walk and simulate its end + a reframe.
        controller.playIdleMotion(.walk, panel: panel, goRight: true, unit: 0.5)
        let walked = controller.wanderOffsetX
        XCTAssertNotEqual(walked, 0)
        let home = defaults.double(forKey: "floatingPetOriginX")
        controller.walkDidFinish()
        controller.panelDidMove(panelOrigin: NSPoint(x: home + walked, y: homeY), userDragging: false)
        XCTAssertEqual(defaults.double(forKey: "floatingPetOriginX"), home, accuracy: 0.001)
    }
}
