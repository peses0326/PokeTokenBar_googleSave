import XCTest
@testable import PokeTokenBar

@MainActor
final class AgentSourceTests: XCTestCase {
    private func event(_ query: String) throws -> AgentActivityEvent {
        let url = try XCTUnwrap(URL(string: "poketokenbar://agent?\(query)"))
        return try XCTUnwrap(AgentActivityEvent(url: url, acceptedSchemes: ["poketokenbar"]))
    }

    // MARK: Parsing untrusted input

    func testAppAndTTYAreParsedAndNormalized() throws {
        let e = try event("state=done&label=web&app=com.apple.Terminal&tty=ttys002")
        XCTAssertEqual(e.source, AgentSource(app: "com.apple.Terminal", tty: "/dev/ttys002"))
        XCTAssertEqual(e.source?.tty, "/dev/ttys002")
    }

    func testSourceIsOptionalAndOldURLsStillWork() throws {
        XCTAssertNil(try event("state=done").source)
        XCTAssertEqual(try event("state=done&app=com.openai.codex").source?.tty, nil, "GUI agents have no tty")
    }

    func testHostileValuesAreDropped() throws {
        XCTAssertNil(try event("state=done&app=Terminal").source, "a bundle id has dots")
        XCTAssertNil(try event("state=done&app=com.apple.Terminal%22%20quit").source, "quotes cannot reach AppleScript")
        XCTAssertNil(try event("state=done&app=" + String(repeating: "a.", count: 80) + "b").source)
        for tty in ["%3F%3F", "/etc/passwd", "ttys002%22", "/dev/ttys0021234", "tty"] {
            XCTAssertNil(try event("state=done&app=com.apple.Terminal&tty=\(tty)").source?.tty, tty)
        }
    }

    func testScriptRefusesAnUnsanitizedTTY() {
        XCTAssertNil(AgentWindowFocuser.tabScript(bundleID: AgentWindowFocuser.terminalBundleID,
                                                  tty: "/dev/ttys1\" then quit"))
        XCTAssertNil(AgentWindowFocuser.tabScript(bundleID: "com.example.Editor", tty: "/dev/ttys001"),
                     "apps without tab scripting are only activated")
        let script = AgentWindowFocuser.tabScript(bundleID: AgentWindowFocuser.terminalBundleID, tty: "/dev/ttys004")
        XCTAssertTrue(script?.contains("\"/dev/ttys004\"") == true)
    }

    // MARK: Tracker and click target

    func testTrackerKeepsTheSourceAndPrefersTheFinishedAgent() throws {
        var tracker = AgentActivityTracker()
        let now = Date()
        tracker.apply(try event("state=waiting&label=a&app=com.googlecode.iterm2&tty=ttys009"), now: now)
        tracker.apply(try event("state=done&label=b&app=com.apple.Terminal&tty=ttys002"), now: now)
        XCTAssertEqual(FloatingPetController.clickTarget(tracker.summary)?.tty, "/dev/ttys002", "done first")
        tracker.expire(now: now.addingTimeInterval(AgentActivityTracker.doneDuration + 1))
        XCTAssertEqual(FloatingPetController.clickTarget(tracker.summary)?.tty, "/dev/ttys009", "then the question")
    }

    func testALaterEventWithoutSourceKeepsTheEarlierOne() throws {
        var tracker = AgentActivityTracker()
        tracker.apply(try event("state=working&label=a&app=com.apple.Terminal&tty=ttys002"), now: Date())
        tracker.apply(try event("state=done&label=a"), now: Date())
        XCTAssertEqual(tracker.summary.done?.source?.tty, "/dev/ttys002")
    }

    // MARK: Click wiring

    func testClickOnAFinishedAgentOpensItsTerminalInsteadOfThePopover() throws {
        let suite = "AgentSourceClick-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.active = MonState(baseID: 1, pathIDs: [1], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        try JSONEncoder().encode(state).write(to: file)
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        var popovers = 0
        let controller = FloatingPetController(store: store, companion: companion, defaults: defaults,
                                               onOpenPopover: { popovers += 1 }, motionOverride: true)
        controller.setDisplayAwake(false)
        store.floatingPetEnabled = true
        var focused: [AgentSource] = []
        var focusSucceeds = true
        controller.focusAgentWindow = { focused.append($0); return focusSucceeds }

        controller.handleAgentEvent(try event("state=done&label=a&app=com.apple.Terminal&tty=ttys002"))
        controller.petClicked()
        XCTAssertEqual(focused.map(\.tty), ["/dev/ttys002"])
        XCTAssertEqual(popovers, 0, "the terminal opens instead")
        XCTAssertNil(controller.tracker.summary.done, "the click still acknowledges the result")

        // The app quit meanwhile: the click falls back to the usual popover.
        focusSucceeds = false
        controller.handleAgentEvent(try event("state=done&label=a&app=com.apple.Terminal&tty=ttys002"))
        controller.petClicked()
        XCTAssertEqual(popovers, 1)

        // No source (old hook): unchanged behaviour, no focus attempt.
        controller.handleAgentEvent(try event("state=done&label=z"))
        let attempts = focused.count
        controller.petClicked()
        XCTAssertEqual(focused.count, attempts, "no source, no focus attempt")
        XCTAssertEqual(popovers, 2)
    }
}
