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
        for tty in ["%3F%3F", "/etc/hosts", "ttys002%22", "/dev/ttys0021234", "tty"] {
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

    // MARK: App links (`open`)

    func testOpenLinkIsParsedForCustomSchemes() throws {
        let e = try event("state=done&app=local.mac-yes-code.app&open=mac-yes-code%3A%2F%2Fsession%2Fyc-a1aa79aa")
        XCTAssertEqual(e.source?.open, URL(string: "mac-yes-code://session/yc-a1aa79aa"))
        XCTAssertNil(try event("state=done&app=com.apple.Terminal").source?.open, "old hooks send no link")
    }

    func testOpenLinkRefusesSharedSchemesAndJunk() throws {
        for raw in ["https%3A%2F%2Fexample.com", "http%3A%2F%2F127.0.0.1%3A8903%2F", "file%3A%2F%2F%2Fetc%2Fhosts",
                    "javascript%3Aalert(1)", "mailto%3Aa%40b.c", "x", "mac-yes-code%3A%2F%2Fa%20b",
                    "mac-yes-code%3A%2F%2F" + String(repeating: "a", count: 300)] {
            XCTAssertNil(try event("state=done&app=local.mac-yes-code.app&open=\(raw)").source?.open, raw)
        }
        XCTAssertNil(try event("state=done&open=mac-yes-code%3A%2F%2Fsession%2Fx").source,
                     "a link without its app is ignored with the rest of the source")
    }

    func testLinkOpensOnlyWhenTheSourceAppOwnsItsScheme() throws {
        let source = try XCTUnwrap(AgentSource(app: "local.mac-yes-code.app", tty: nil,
                                               open: "mac-yes-code://session/yc-a1aa79aa"))
        XCTAssertEqual(AgentWindowFocuser.openableLink(source, handlerBundleID: { _ in "local.mac-yes-code.app" }),
                       source.open)
        XCTAssertNil(AgentWindowFocuser.openableLink(source, handlerBundleID: { _ in "com.evil.app" }),
                     "another app's scheme is never opened")
        XCTAssertNil(AgentWindowFocuser.openableLink(source, handlerBundleID: { _ in nil }), "no handler, no open")
    }

    func testFocusOpensTheOwnedLinkOfARunningApp() throws {
        // Finder is always running, so this reaches the link branch without launching anything.
        let source = try XCTUnwrap(AgentSource(app: "com.apple.finder", tty: nil, open: "finder-test://x"))
        var opened: [URL] = []
        XCTAssertTrue(AgentWindowFocuser.focus(source, handlerBundleID: { _ in "com.apple.finder" },
                                               openURL: { opened.append($0); return true }))
        XCTAssertEqual(opened, [URL(string: "finder-test://x")!])
        let absent = try XCTUnwrap(AgentSource(app: "com.example.not-running", tty: nil, open: "nr-test://x"))
        XCTAssertFalse(AgentWindowFocuser.focus(absent, handlerBundleID: { _ in "com.example.not-running" },
                                                openURL: { opened.append($0); return true }))
        XCTAssertEqual(opened.count, 1, "a closed app is never launched through its link")
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
