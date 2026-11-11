import Foundation

/// Application Support state directory for PokeTokenBar files.
/// `PTB_STATE_DIR` overrides the default for development/QA isolation.
enum AppStatePaths {
    /// State folder of the Google-sync build (`PTBCloudPreview`). It matches the app name.
    static let googleSaveFolderName = "PokeTokenBar_GoogleSave"
    /// Folder and bundle id used by the earlier "PokeTokenBar Google Preview" build.
    static let legacyPreviewFolderName = "PokeTokenBar-GooglePreview"
    static let legacyPreviewBundleID = "io.github.chattymin.poketokenbar.google-preview"
    private static let migrationMarker = ".migrated-from-google-preview"

    static func directory() -> URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(AppEnv.isCloudPreview ? googleSaveFolderName : "PokeTokenBar")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Carry the preview build's save, Google credentials and settings over to the renamed app once.
    ///
    /// Copies (never moves) so the old folder stays as a backup. Items already present in the new
    /// folder win: logging or caches may have created the folder before this runs, so an existing
    /// destination folder is not a signal that migration already happened — the marker file is.
    @discardableResult
    static func migrateLegacyPreview(from legacy: URL, to current: URL,
                                     defaults: UserDefaults, legacyDefaults: [String: Any]?,
                                     fileManager fm: FileManager = .default) -> Bool {
        let marker = current.appendingPathComponent(migrationMarker)
        guard !fm.fileExists(atPath: marker.path), fm.fileExists(atPath: legacy.path) else { return false }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let target = current.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
        }
        for (key, value) in legacyDefaults ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        fm.createFile(atPath: marker.path, contents: Data())
        return true
    }

    static func migrateLegacyPreviewIfNeeded() {
        guard AppEnv.isCloudPreview,
              (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "").isEmpty else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaults = UserDefaults.standard
        if migrateLegacyPreview(from: base.appendingPathComponent(legacyPreviewFolderName),
                                to: base.appendingPathComponent(googleSaveFolderName),
                                defaults: defaults,
                                legacyDefaults: defaults.persistentDomain(forName: legacyPreviewBundleID)) {
            AppLog.write("migrated state from \(legacyPreviewFolderName)")
        }
    }
}
