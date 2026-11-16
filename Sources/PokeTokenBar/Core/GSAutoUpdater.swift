import AppKit
import CryptoKit
import Observation

/// Automatic updates for the PokeTokenBar_gs build: at most once a day it reads this fork's latest
/// GitHub release, and when it is newer downloads `PokeTokenBar_gs.zip`, checks it, swaps the app
/// bundle and relaunches. The original app's `UpdateChecker` stays off in this build (its banner and
/// `brew upgrade` would install the original app).
///
/// Trust: the download must come from this repository's release assets over HTTPS and match the
/// SHA-256 digest GitHub publishes for the asset; the unzipped app must carry this app's bundle id
/// and the release's version and pass `codesign --verify`. Anything else leaves the app untouched.
@MainActor
@Observable
final class GSAutoUpdater {
    struct Release: Equatable, Sendable {
        let version: String
        let zipURL: URL
        /// Lowercase hex SHA-256 of the zip, from the release asset's `digest`.
        let sha256: String
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case installing(String)
        case failed(String)
    }

    nonisolated static let repository = "peses0326/PokeTokenBar_googleSave"
    nonisolated static let assetName = "PokeTokenBar_gs.zip"
    nonisolated static let tagPrefix = "gs-v"
    static let enabledKey = "gsAutoUpdateEnabled"
    static let lastCheckKey = "gsAutoUpdateLastCheck"
    /// One automatic check a day.
    static let checkInterval: TimeInterval = 24 * 3600

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?

    let currentVersion: String
    private let clock: () -> Date
    private let defaults: UserDefaults
    private let fetchLatest: () async -> Release?
    /// Downloads, verifies and starts the swap. Returns an error message, or nil once the
    /// relaunch is scheduled (the app then quits).
    private let install: (Release) async -> String?
    private var inFlight = false

    init(currentVersion: String? = nil, clock: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard,
         fetchLatest: (() async -> Release?)? = nil, install: ((Release) async -> String?)? = nil) {
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        self.clock = clock
        self.defaults = defaults
        self.fetchLatest = fetchLatest ?? { await GSAutoUpdater.liveLatestRelease() }
        self.install = install ?? { await GSAutoUpdater.liveInstall($0) }
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Whether the daily check is due now.
    var isDue: Bool {
        guard isEnabled else { return false }
        guard let lastCheck else { return true }
        return clock().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    /// Called after every usage refresh: checks and installs when a day has passed.
    func runIfDue() async {
        guard isDue else { return }
        await checkAndInstall()
    }

    /// Settings' *Check now*: ignores the daily limit and the switch.
    func checkNow() async {
        await checkAndInstall()
    }

    private func checkAndInstall() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        status = .checking
        guard let release = await fetchLatest() else {
            // A failed check does not count as the day's check, so the next refresh retries.
            status = .failed("check")
            return
        }
        lastCheck = clock()
        defaults.set(lastCheck, forKey: Self.lastCheckKey)
        guard UpdateChecker.isNewer(release.version, than: currentVersion) else {
            status = .upToDate(currentVersion)
            return
        }
        status = .installing(release.version)
        AppLog.write("gs-update: installing \(release.version) over \(currentVersion)")
        if let error = await install(release) {
            AppLog.write("gs-update: \(error)")
            status = .failed(error)
        }
    }

    // MARK: Release parsing

    /// `gs-v0.4.3` → `0.4.3`; anything else (upstream tags, prereleases) → nil.
    nonisolated static func version(fromTag tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(tagPrefix) else { return nil }
        return UpdateChecker.normalizedReleaseVersion(String(trimmed.dropFirst(tagPrefix.count)))
    }

    /// Only this repository's release downloads, over HTTPS.
    nonisolated static func isTrustedDownloadURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
            && url.lastPathComponent == assetName
    }

    /// GitHub `releases/latest` JSON → release, or nil when any piece is missing or untrusted.
    nonisolated static func parseLatest(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, let version = version(fromTag: tag),
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String, let url = URL(string: link),
              isTrustedDownloadURL(url),
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return Release(version: version, zipURL: url, sha256: hex)
    }

    private nonisolated static func liveLatestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseLatest(data)
    }

    // MARK: Install

    nonisolated static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The unzipped app is this app at the release's version, with an intact signature.
    nonisolated static func validateDownloadedApp(_ app: URL, expectedBundleID: String, expectedVersion: String) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            return "no Info.plist"
        }
        guard info["CFBundleIdentifier"] as? String == expectedBundleID else { return "bundle id mismatch" }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else { return "version mismatch" }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { return "signature" }
        return nil
    }

    /// Replaces the bundle after this process exits, restores the old one if the copy fails, then
    /// relaunches. Arguments are positional ($1 new app, $2 installed bundle, $3 pid, $4 work dir),
    /// so no path is interpolated into the script.
    nonisolated static let swapScript = """
    for i in $(seq 1 40); do kill -0 "$3" 2>/dev/null || break; sleep 0.5; done
    backup="$4/previous.app"
    if mv "$2" "$backup"; then
      if ditto "$1" "$2"; then
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
      else
        rm -rf "$2"; mv "$backup" "$2"
      fi
    fi
    for i in $(seq 1 15); do open "$2" 2>/dev/null && break; sleep 1; done
    rm -rf "$4"
    """

    private nonisolated static func liveInstall(_ release: Release) async -> String? {
        let bundle = Bundle.main.bundleURL
        guard AppEnv.isGoogleSaveVersion, AppEnv.isBundledApp, let bundleID = Bundle.main.bundleIdentifier else {
            return "not the installed _gs app"
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            return "cannot write \(bundle.deletingLastPathComponent().path)"
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gs-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let zip = work.appendingPathComponent(assetName)
            try FileManager.default.moveItem(at: downloaded, to: zip)
            guard try sha256Hex(of: zip) == release.sha256 else {
                try? FileManager.default.removeItem(at: work)
                return "digest mismatch"
            }
            let unpacked = work.appendingPathComponent("new")
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else {
                try? FileManager.default.removeItem(at: work)
                return "unzip"
            }
            let app = unpacked.appendingPathComponent(bundle.lastPathComponent)
            if let problem = validateDownloadedApp(app, expectedBundleID: bundleID, expectedVersion: release.version) {
                try? FileManager.default.removeItem(at: work)
                return problem
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", swapScript, "sh", app.path, bundle.path,
                              String(ProcessInfo.processInfo.processIdentifier), work.path]
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            return "download: \(error.localizedDescription)"
        }
        await MainActor.run { NSApp.terminate(nil) }
        return nil
    }

    private nonisolated static func run(_ binary: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
