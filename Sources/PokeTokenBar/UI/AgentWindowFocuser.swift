import AppKit

/// Brings the window an agent runs in to the front when the pet is clicked.
/// Terminal and iTerm2 select the exact tab by tty (Automation permission, asked once by macOS);
/// any other app — or a refused permission — is simply activated. Never launches anything:
/// the source comes from an untrusted URL, so only an app that is already running is touched.
@MainActor
enum AgentWindowFocuser {
    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    /// Returns false when the app is not running, so the click falls back to its usual action.
    @discardableResult
    static func focus(_ source: AgentSource) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.app).first
        else { return false }
        if let tty = source.tty, let script = tabScript(bundleID: source.app, tty: tty) {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil, result?.booleanValue == true { return true }
        }
        app.activate()
        return true
    }

    /// AppleScript that selects the tab whose tty matches and returns true, or nil for apps with
    /// no tab scripting. `tty` is interpolated, so it must already be `AgentSource.sanitizedTTY`
    /// output (`/dev/ttys` + digits) — anything else is refused here too.
    static func tabScript(bundleID: String, tty: String) -> String? {
        guard AgentSource.sanitizedTTY(tty) == tty else { return nil }
        switch bundleID {
        case terminalBundleID:
            return """
            tell application id "\(terminalBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case iTermBundleID:
            return """
            tell application id "\(iTermBundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }
}
