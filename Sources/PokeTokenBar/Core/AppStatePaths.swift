import Foundation

/// Application Support state directory for PokeTokenBar files.
/// `PTB_STATE_DIR` overrides the default for development/QA isolation.
enum AppStatePaths {
    /// State folder of the Google-sync build (`PTBCloudPreview`), shared with no other build so saves,
    /// settings and permissions never mix with the original app or older previews. The app is now named
    /// PokeTokenBar_gs; the folder and bundle id keep the earlier PokemonTokenBar_gs spelling so existing
    /// saves and Google sign-in carry on.
    static let googleSyncFolderName = "PokemonTokenBar_gs"

    static func directory() -> URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(AppEnv.isCloudPreview ? googleSyncFolderName : "PokeTokenBar")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
