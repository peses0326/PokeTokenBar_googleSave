import XCTest
@testable import PokeTokenBar

/// The Google-sync build was renamed (bundle id + state folder). Its save and Google credentials
/// must survive the rename, and the copy must never clobber what the renamed app already wrote.
final class GoogleSaveMigrationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gs-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "gs-migration-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testCopiesSaveCredentialsAndDefaultsIntoNewFolder() throws {
        let legacy = root.appendingPathComponent("legacy"), current = root.appendingPathComponent("current")
        try write("save", "companion-state.json", in: legacy)
        try write("creds", "google-sync/credentials.json", in: legacy)

        XCTAssertTrue(AppStatePaths.migrateLegacyPreview(
            from: legacy, to: current, defaults: defaults,
            legacyDefaults: ["googleSyncEnabled": true, "googleSyncEmail": "a@example.com"]))

        XCTAssertEqual(read("companion-state.json", in: current), "save")
        XCTAssertEqual(read("google-sync/credentials.json", in: current), "creds")
        XCTAssertEqual(read("companion-state.json", in: legacy), "save", "legacy folder stays as a backup")
        XCTAssertTrue(defaults.bool(forKey: "googleSyncEnabled"))
        XCTAssertEqual(defaults.string(forKey: "googleSyncEmail"), "a@example.com")
    }

    /// Logging can create the new folder before migration runs — an existing folder must not
    /// block the copy, and files the new app already wrote must win.
    func testExistingDestinationFolderStillMigratesWithoutOverwriting() throws {
        let legacy = root.appendingPathComponent("legacy"), current = root.appendingPathComponent("current")
        try write("old-save", "companion-state.json", in: legacy)
        try write("old-log", "app.log", in: legacy)
        try write("new-log", "app.log", in: current)
        defaults.set("ko", forKey: "language")

        XCTAssertTrue(AppStatePaths.migrateLegacyPreview(
            from: legacy, to: current, defaults: defaults, legacyDefaults: ["language": "en"]))

        XCTAssertEqual(read("companion-state.json", in: current), "old-save")
        XCTAssertEqual(read("app.log", in: current), "new-log")
        XCTAssertEqual(defaults.string(forKey: "language"), "ko")
    }

    func testRunsOnlyOnce() throws {
        let legacy = root.appendingPathComponent("legacy"), current = root.appendingPathComponent("current")
        try write("save", "companion-state.json", in: legacy)
        XCTAssertTrue(AppStatePaths.migrateLegacyPreview(from: legacy, to: current, defaults: defaults, legacyDefaults: nil))
        try FileManager.default.removeItem(at: current.appendingPathComponent("companion-state.json"))

        XCTAssertFalse(AppStatePaths.migrateLegacyPreview(from: legacy, to: current, defaults: defaults, legacyDefaults: nil))
        XCTAssertNil(read("companion-state.json", in: current), "a deliberate deletion must not be resurrected")
    }

    func testNoLegacyFolderIsANoOp() {
        let current = root.appendingPathComponent("current")
        XCTAssertFalse(AppStatePaths.migrateLegacyPreview(
            from: root.appendingPathComponent("missing"), to: current, defaults: defaults, legacyDefaults: ["k": 1]))
        XCTAssertNil(defaults.object(forKey: "k"))
    }
}
