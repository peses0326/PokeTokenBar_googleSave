import CryptoKit
import Foundation
import Observation

enum CloudSyncError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

struct CloudGameSettings: Codable, Sendable {
    let growthDifficulty: Double
    let shopDifficulty: Double
}

struct GoogleOAuthClient: Sendable {
    let clientID: String
    var clientSecret: String = ""
    var isValid: Bool {
        clientID.range(of: #"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil
    }
    static var bundled: GoogleOAuthClient? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "PTBGoogleOAuthClientID") as? String,
              id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return GoogleOAuthClient(clientID: id,
            clientSecret: Bundle.main.object(forInfoDictionaryKey: "PTBGoogleOAuthClientSecret") as? String ?? "")
    }
}

/// Cloud imports carry the account's usage claims, unlike a manual save transfer's
/// device-local rebasing. Otherwise switching Macs grants the same server tokens twice.
extension CompanionStore {
    func applyCloudSave(_ data: Data, usage: UsageStore) throws {
        let envelope = try SaveTransfer.decode(data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var settings: CloudGameSettings?
        if let raw = object?["gameSettings"] {
            let value = try JSONDecoder().decode(CloudGameSettings.self, from: JSONSerialization.data(withJSONObject: raw))
            guard value.growthDifficulty.isFinite, value.shopDifficulty.isFinite,
                  PokemonBalance.clampDifficulty(value.growthDifficulty) == value.growthDifficulty,
                  PokemonBalance.clampDifficulty(value.shopDifficulty) == value.shopDifficulty else {
                throw CloudSyncError.message("Cloud game settings are outside the supported range")
            }
            settings = value
        }
        try applySave(envelope, todayTokensByProvider: usage.dailyGrowthTokensByProvider,
                      todayDate: LocalUsageReader.todayKey(), hasUsageData: usage.hasUsageData,
                      cloudUsageClaims: envelope.state.claimedCumulativeTokens, cloudGameSettings: settings)
    }
}

@MainActor
@Observable
final class GoogleCloudSync {
    struct Head: Decodable, Identifiable, Sendable {
        let revision: String
        let writer: String
        var label: String?
        var savedAt: String?
        var id: String { revision }
    }
    struct Account: Decodable, Sendable { let sub: String; let email: String }
    struct Reply: Decodable, Sendable {
        let status: String
        var account: Account?
        var heads: [Head]?
        var clock: [String: Int]?
        var digest: String?
        var folderURL: String?
    }
    typealias Runner = @Sendable ([String], TimeInterval) async throws -> Data

    private(set) var enabled: Bool
    private(set) var busy = false
    private(set) var status = "disconnected"
    private(set) var email: String
    private(set) var errorMessage: String?
    private(set) var heads: [Head] = []
    private(set) var lastSync: Date?
    private(set) var driveFolderURL: URL?
    var loginConfigured: Bool { oauthClient?.isValid == true }
    private let directory: URL
    private let defaults: UserDefaults
    private let runner: Runner
    private let oauthClient: GoogleOAuthClient?
    private var nextSync = Date.distantPast
    private var generation = 0

    init(directory: URL = AppStatePaths.directory().appendingPathComponent("google-sync"),
         defaults: UserDefaults = .standard, oauthClient: GoogleOAuthClient? = .bundled,
         runner: @escaping Runner = GoogleCloudSync.runHelper) {
        self.directory = directory
        self.defaults = defaults
        self.runner = runner
        self.oauthClient = oauthClient
        self.enabled = defaults.bool(forKey: "googleSyncEnabled")
        self.email = defaults.string(forKey: "googleSyncEmail") ?? ""
        self.status = enabled ? "connected" : "disconnected"
    }

    nonisolated static func runHelper(_ arguments: [String], _ timeout: TimeInterval) async throws -> Data {
        let script: URL?
        if AppEnv.isBundledApp {
            script = Bundle.main.resourceURL.flatMap { packagedHelper(in: $0) }
        } else {
            script = Bundle.module.url(forResource: "CloudSync", withExtension: nil)?.appendingPathComponent("google_sync.py")
        }
        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            throw CloudSyncError.message("The bundled Google sync helper is missing")
        }
        guard let python = BinaryLocator.resolve("python3", staticPaths: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]) else {
            throw CloudSyncError.message("Python 3.9 or later is required for Google sync")
        }
        return try await ProcessRunner.runCommand(binary: python, arguments: [script.path] + arguments, timeout: timeout)
    }

    nonisolated static func packagedHelper(in resources: URL) -> URL? {
        let file = resources.appendingPathComponent("PokeTokenBar_PokeTokenBar.bundle/CloudSync/google_sync.py")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 90) async throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try await runner(["--state-dir", directory.path] + arguments, timeout)
    }

    func connect() async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        let clientFile = directory.appendingPathComponent("oauth-app-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: clientFile) }
        do {
            guard let oauthClient, oauthClient.isValid else {
                throw CloudSyncError.message("This build needs the app developer’s Google OAuth client ID before sign-in can be enabled")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: ["installed": ["client_id": oauthClient.clientID,
                                                                               "client_secret": oauthClient.clientSecret]])
            try data.write(to: clientFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientFile.path)
            let response = try await run(["authorize", "--client", clientFile.path], timeout: 300)
            let reply = try JSONDecoder().decode(Reply.self, from: response)
            guard let account = reply.account, reply.status == "connected" else {
                throw CloudSyncError.message("Google login did not complete")
            }
            email = account.email; enabled = true; status = "connected"
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent("cloud-usage.json"))
            defaults.set(true, forKey: "googleSyncEnabled")
            defaults.set(email, forKey: "googleSyncEmail")
            generation += 1; nextSync = .distantPast
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        do {
            _ = try await run(["disconnect"])
            enabled = false; status = "disconnected"; email = ""; heads = []
            driveFolderURL = nil
            defaults.set(false, forKey: "googleSyncEnabled")
            defaults.removeObject(forKey: "googleSyncEmail")
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent("cloud-usage.json"))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func syncIfDue(companion: CompanionStore, usage: UsageStore) {
        guard enabled, !busy, Date() >= nextSync, !["empty", "choose", "conflict"].contains(status) else { return }
        nextSync = Date().addingTimeInterval(1800)
        Task { await synchronize(companion: companion, usage: usage) }
    }

    static func gameplayDigest(_ state: CompanionState, settings: CloudGameSettings? = nil) throws -> String {
        let data = try JSONEncoder().encode(state)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["claimedTodayTokensByProvider", "lastDate", "installBaselineSet", "language"] { object.removeValue(forKey: key) }
        for key in ["collectedFinals", "notifiedDexCompletions"] {
            if let values = object[key] as? [String] { object[key] = values.sorted() }
        }
        if let settings { object["gameSettings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) }
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
    }

    func synchronize(companion: CompanionStore, usage: UsageStore, resolution: String? = nil,
                     revision: String? = nil) async {
        guard enabled, !busy else { return }
        busy = true; errorMessage = nil
        nextSync = Date().addingTimeInterval(1800)
        defer { busy = false }
        let operationGeneration = generation
        let request = directory.appendingPathComponent("request-\(UUID().uuidString).json")
        let ack = directory.appendingPathComponent("ack-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: ack) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let settings = CloudGameSettings(growthDifficulty: companion.growthDifficulty, shopDifficulty: companion.shopDifficulty)
            let captured = try Self.gameplayDigest(companion.state, settings: settings)
            let exported = try companion.exportedSaveData(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                                                          deviceName: Host.current().localizedName ?? "Mac")
            var payload = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
            payload["gameSettings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
            let snapshot = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try snapshot.write(to: request, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
            var arguments = ["exchange", "--request", request.path]
            if let resolution { arguments += ["--resolution", resolution] }
            if let revision { arguments += ["--revision", revision] }
            let data = try await run(arguments)
            guard generation == operationGeneration else { return }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CloudSyncError.message("Invalid cloud response")
            }
            heads = reply.heads ?? []
            if let account = reply.account { email = account.email }
            if let raw = reply.folderURL, let url = URL(string: raw), url.scheme == "https", url.host == "drive.google.com" {
                driveFolderURL = url
            }
            if ["empty", "choose", "conflict"].contains(reply.status) {
                status = reply.status
                return  // Do not apply remote usage against an unresolved game branch.
            }
            if reply.status == "download" {
                let currentSettings = CloudGameSettings(growthDifficulty: companion.growthDifficulty, shopDifficulty: companion.shopDifficulty)
                guard try Self.gameplayDigest(companion.state, settings: currentSettings) == captured else {
                    status = "conflict"
                    throw CloudSyncError.message("Your game changed during sync. Both versions are preserved; sync again to choose.")
                }
                guard let save = object["save"], let revisionClock = reply.clock, let digest = reply.digest else {
                    throw CloudSyncError.message("Cloud response is missing the game revision")
                }
                let remote = try JSONSerialization.data(withJSONObject: save)
                // The importer backs up local progress before any state replacement.
                try companion.applyCloudSave(remote, usage: usage)
                try JSONSerialization.data(withJSONObject: ["clock": revisionClock, "digest": digest]).write(to: ack, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ack.path)
                _ = try await run(["ack", "--request", ack.path])
            } else if !["uploaded", "unchanged"].contains(reply.status) {
                throw CloudSyncError.message("Unknown cloud synchronization result")
            }
            if let summaries = object["usage"] as? [[String: Any]] {
                let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "summaries": summaries])
                let candidate = directory.appendingPathComponent("usage-candidate-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: candidate) }
                guard payload.count <= CloudUsageCache.maxBytes else { throw CloudSyncError.message("Cloud usage exceeds its limit") }
                try payload.write(to: candidate, options: .atomic)
                _ = try await CloudUsageCache(file: candidate).load()
                try payload.write(to: directory.deletingLastPathComponent().appendingPathComponent("cloud-usage.json"), options: .atomic)
            }
            status = "synced"; lastSync = Date()
            await usage.refresh()
        } catch { errorMessage = error.localizedDescription }
    }
}
