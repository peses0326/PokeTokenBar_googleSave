import XCTest
@testable import PokeTokenBar

@MainActor
final class GSAutoUpdaterTests: XCTestCase {
    private let zip = URL(string: "https://github.com/peses0326/PokeTokenBar_googleSave/releases/download/gs-v0.5.0/PokeTokenBar_gs.zip")!
    private let digest = String(repeating: "ab", count: 32)

    private func defaults() -> UserDefaults {
        let suite = "gs-update-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Parsing untrusted release data

    func testTagsOutsideTheForkScheme() {
        XCTAssertEqual(GSAutoUpdater.version(fromTag: "gs-v0.4.3"), "0.4.3")
        XCTAssertEqual(GSAutoUpdater.version(fromTag: " gs-v1.10.0 "), "1.10.0")
        for tag in ["v2.5.7", "0.4.3", "gs-v0.4", "gs-v0.4.3-beta", "gs-vX.Y.Z", "GS-v0.4.3"] {
            XCTAssertNil(GSAutoUpdater.version(fromTag: tag), tag)
        }
    }

    func testOnlyThisRepositorysReleaseAssetIsTrusted() {
        XCTAssertTrue(GSAutoUpdater.isTrustedDownloadURL(zip))
        for raw in ["http://github.com/peses0326/PokeTokenBar_googleSave/releases/download/gs-v0.5.0/PokeTokenBar_gs.zip",
                    "https://github.com/chattymin/PokeTokenBar/releases/download/v2.5.7/PokeTokenBar_gs.zip",
                    "https://evil.example/peses0326/PokeTokenBar_googleSave/releases/download/gs-v0.5.0/PokeTokenBar_gs.zip",
                    "https://github.com/peses0326/PokeTokenBar_googleSave/releases/download/gs-v0.5.0/Other.zip",
                    "https://github.com/peses0326/PokeTokenBar_googleSave/archive/main.zip"] {
            XCTAssertFalse(GSAutoUpdater.isTrustedDownloadURL(URL(string: raw)!), raw)
        }
    }

    private func releaseJSON(tag: String = "gs-v0.5.0", url: String? = nil, digest: String? = nil,
                             name: String = "PokeTokenBar_gs.zip", prerelease: Bool = false) -> Data {
        var asset: [String: Any] = ["name": name, "browser_download_url": url ?? zip.absoluteString]
        asset["digest"] = digest ?? "sha256:\(self.digest)"
        let json: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": prerelease, "assets": [asset]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParseLatestNeedsTagAssetTrustedURLAndDigest() {
        XCTAssertEqual(GSAutoUpdater.parseLatest(releaseJSON()),
                       GSAutoUpdater.Release(version: "0.5.0", zipURL: zip, sha256: digest))
        XCTAssertEqual(GSAutoUpdater.parseLatest(releaseJSON(digest: "sha256:" + digest.uppercased()))?.sha256, digest)
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(tag: "v2.5.7")))
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(name: "PokeTokenBar.zip")))
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(url: "https://evil.example/PokeTokenBar_gs.zip")))
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(digest: "md5:abc")))
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(digest: "sha256:1234")))
        XCTAssertNil(GSAutoUpdater.parseLatest(releaseJSON(prerelease: true)))
        XCTAssertNil(GSAutoUpdater.parseLatest(Data("not json".utf8)))
    }

    // MARK: Schedule and switch

    func testDailyScheduleSwitchAndInstallDecision() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var fetches = 0, installs: [String] = []
        var latest: GSAutoUpdater.Release? = GSAutoUpdater.Release(version: "0.4.2", zipURL: zip, sha256: digest)
        let store = defaults()
        let updater = GSAutoUpdater(currentVersion: "0.4.2", clock: { now }, defaults: store,
                                    fetchLatest: { fetches += 1; return latest },
                                    install: { installs.append($0.version); return nil })
        XCTAssertTrue(updater.isEnabled, "on by default")

        await updater.runIfDue()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(updater.status, .upToDate("0.4.2"))
        XCTAssertTrue(installs.isEmpty, "same version is not reinstalled")

        now += 23 * 3600
        await updater.runIfDue()
        XCTAssertEqual(fetches, 1, "at most once a day")

        now += 2 * 3600
        latest = GSAutoUpdater.Release(version: "0.5.0", zipURL: zip, sha256: digest)
        await updater.runIfDue()
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(installs, ["0.5.0"])
        XCTAssertEqual(updater.status, .installing("0.5.0"))

        updater.isEnabled = false
        now += 48 * 3600
        await updater.runIfDue()
        XCTAssertEqual(fetches, 2, "switched off: no automatic check")
        XCTAssertEqual(store.object(forKey: GSAutoUpdater.enabledKey) as? Bool, false, "the switch persists")

        await updater.checkNow()
        XCTAssertEqual(fetches, 3, "Check now still works with the switch off")

        let reloaded = GSAutoUpdater(currentVersion: "0.4.2", clock: { now }, defaults: store,
                                     fetchLatest: { nil }, install: { _ in nil })
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.lastCheck, now)
    }

    func testFailedCheckRetriesAndFailedInstallIsReported() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var latest: GSAutoUpdater.Release?
        var fetches = 0
        let updater = GSAutoUpdater(currentVersion: "0.4.2", clock: { now }, defaults: defaults(),
                                    fetchLatest: { fetches += 1; return latest }, install: { _ in "digest mismatch" })
        await updater.runIfDue()
        XCTAssertEqual(updater.status, .failed("check"))
        XCTAssertNil(updater.lastCheck, "a failed check is not the day's check")
        await updater.runIfDue()
        XCTAssertEqual(fetches, 2, "retried on the next refresh")

        latest = GSAutoUpdater.Release(version: "0.4.3", zipURL: zip, sha256: digest)
        await updater.runIfDue()
        XCTAssertEqual(updater.status, .failed("digest mismatch"))
    }

    // MARK: Verification and swap

    func testSHA256OfAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gs-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try GSAutoUpdater.sha256Hex(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func fakeApp(at url: URL, bundleID: String, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
    }

    func testDownloadedAppMustBeThisAppAtTheReleaseVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gs-validate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("PokeTokenBar_gs.app")
        try fakeApp(at: app, bundleID: "io.github.peses0326.poketokenbar-gs", version: "0.5.0", marker: "new")
        XCTAssertEqual(GSAutoUpdater.validateDownloadedApp(app, expectedBundleID: "com.example.other", expectedVersion: "0.5.0"),
                       "bundle id mismatch")
        XCTAssertEqual(GSAutoUpdater.validateDownloadedApp(app, expectedBundleID: "io.github.peses0326.poketokenbar-gs",
                                                           expectedVersion: "0.4.9"), "version mismatch")
        XCTAssertEqual(GSAutoUpdater.validateDownloadedApp(app, expectedBundleID: "io.github.peses0326.poketokenbar-gs",
                                                           expectedVersion: "0.5.0"), "signature", "unsigned bundle")
    }

    /// Runs the real swap script with a stub `open` and an already-exited pid.
    private func runSwap(newApp: URL, installed: URL, work: URL, binDir: URL) throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run(); finished.waitUntilExit()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", GSAutoUpdater.swapScript, "sh", newApp.path, installed.path,
                          String(finished.processIdentifier), work.path]
        task.environment = ["PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        try task.run(); task.waitUntilExit()
    }

    func testSwapReplacesTheBundleOrRestoresTheOldOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gs-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let openLog = root.appendingPathComponent("opened")
        let stub = bin.appendingPathComponent("open")
        try "#!/bin/sh\necho \"$1\" >> \"\(openLog.path)\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let installed = root.appendingPathComponent("Applications/PokeTokenBar_gs.app")
        try fakeApp(at: installed, bundleID: "x", version: "0.4.2", marker: "old")
        let work = root.appendingPathComponent("work")
        let newApp = work.appendingPathComponent("new/PokeTokenBar_gs.app")
        try fakeApp(at: newApp, bundleID: "x", version: "0.5.0", marker: "new")

        try runSwap(newApp: newApp, installed: installed, work: work, binDir: bin)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "work dir and backup removed")
        XCTAssertEqual(try String(contentsOf: openLog, encoding: .utf8), installed.path + "\n", "relaunched")

        // The copy fails (new app missing): the previous bundle comes back and still relaunches.
        let work2 = root.appendingPathComponent("work2")
        try FileManager.default.createDirectory(at: work2, withIntermediateDirectories: true)
        try runSwap(newApp: work2.appendingPathComponent("missing.app"), installed: installed, work: work2, binDir: bin)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "new",
                       "old bundle restored")
        XCTAssertEqual(try String(contentsOf: openLog, encoding: .utf8).split(separator: "\n").count, 2)
    }
}
