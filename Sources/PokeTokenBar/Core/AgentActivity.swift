import Foundation

/// What an external coding agent last reported through `poketokenbar://agent?state=…`.
/// Agent-agnostic: any tool that can open a URL drives the same states.
enum AgentActivity: Equatable, Sendable {
    case idle
    case working
    case waiting(message: String?)
    case done(message: String?)
}

/// Where an agent runs, so a click on the pet can bring that window forward. Both fields come
/// from an untrusted URL: they are only ever matched against running apps and open terminal tabs.
struct AgentSource: Equatable, Sendable {
    /// Bundle id of the app hosting the agent (a hook's `$__CFBundleIdentifier`).
    var app: String
    /// Controlling terminal of the agent, e.g. `/dev/ttys002`; nil for GUI agents.
    var tty: String?

    init?(app: String?, tty: String?) {
        guard let app, app.count <= 128,
              app.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
        else { return nil }
        self.app = app
        self.tty = Self.sanitizedTTY(tty)
    }

    /// `ttys002` and `/dev/ttys002` both become `/dev/ttys002`; anything else (`??`, paths) is dropped.
    static func sanitizedTTY(_ raw: String?) -> String? {
        guard var tty = raw?.trimmingCharacters(in: .whitespaces), !tty.isEmpty else { return nil }
        if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
        guard tty.range(of: #"^/dev/ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil else { return nil }
        return tty
    }
}

/// One parsed `poketokenbar://agent?state=<working|waiting|done|idle>[&message=<text>][&label=<name>][&app=<bundle id>][&tty=<tty>]` URL.
struct AgentActivityEvent: Equatable, Sendable {
    static let scheme = "poketokenbar"
    /// Schemes this build answers: the default plus any it registers in `CFBundleURLTypes`, so a build
    /// installed beside the original can claim its own scheme and the two never share agent URLs.
    static let acceptedSchemes: Set<String> = registeredSchemes(in: Bundle.main.infoDictionary).union([scheme])

    static func registeredSchemes(in info: [String: Any]?) -> Set<String> {
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() })
    }
    static let host = "agent"
    /// Any app or web page can open the URL, so the message size is bounded here. These are size
    /// limits on untrusted input, not layout: `fittedBubbleBody` makes the text fit the bubble.
    static let maxMessageLength = 80
    /// Characters can stack any number of combining marks, so scalars are bounded too —
    /// otherwise 80 characters could carry thousands of scalars into text measuring.
    static let maxMessageScalars = maxMessageLength * 4
    /// Names one agent among several (e.g. a project folder). Short: it shares the title line.
    static let maxLabelLength = 24

    let activity: AgentActivity
    /// Nil is the one unlabeled agent, so URLs without a label behave as before.
    let label: String?
    /// Nil when the hook did not say where the agent runs.
    let source: AgentSource?

    /// Nil for any other scheme, host or state — unknown input is ignored, never an error.
    init?(url: URL, acceptedSchemes: Set<String> = Self.acceptedSchemes) {
        guard let scheme = url.scheme?.lowercased(), acceptedSchemes.contains(scheme),
              url.host?.lowercased() == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value?.lowercased()
        else { return nil }
        let message = Self.sanitizedMessage(items.first(where: { $0.name == "message" })?.value)
        label = Self.sanitizedLabel(items.first(where: { $0.name == "label" })?.value)
        source = AgentSource(app: items.first(where: { $0.name == "app" })?.value,
                             tty: items.first(where: { $0.name == "tty" })?.value)
        switch state {
        case "idle": activity = .idle
        case "working": activity = .working
        case "waiting": activity = .waiting(message: message)
        case "done": activity = .done(message: message)
        default: return nil
        }
    }

    static func sanitizedMessage(_ raw: String?) -> String? { sanitized(raw, maxLength: maxMessageLength) }
    static func sanitizedLabel(_ raw: String?) -> String? { sanitized(raw, maxLength: maxLabelLength) }

    /// Plain single-line text: control characters become spaces, invisible format characters
    /// (bidi overrides, zero-width spaces) are dropped, whitespace runs collapse, and anything
    /// past 4× `maxLength` scalars or `maxLength` characters is cut with an ellipsis.
    /// Empty input → nil.
    private static func sanitized(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let maxScalars = maxLength * 4
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: scalars.append(" ")
            // U+200D joins emoji sequences; dropping it would split them apart.
            case .format where scalar.value != 0x200D: continue
            default: scalars.append(scalar)
            }
        }
        var text = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if text.unicodeScalars.count > maxScalars {
            text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxScalars - 1)))
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What the pet shows across every agent it heard from.
struct AgentActivitySummary: Equatable, Sendable {
    struct Note: Equatable, Sendable {
        var label: String?
        var message: String?
        var source: AgentSource?
    }

    /// The latest `done`: a transient overlay over everything else.
    var done: Note?
    /// The most recently waiting agent; `otherWaitingCount` more are waiting behind it.
    var waiting: Note?
    var otherWaitingCount = 0
    var working = false
}

/// Pure state machine behind the floating pet's agent reactions, one entry per label.
/// Time comes in as arguments, so tests drive expirations without sleeping; the caller arms
/// one timer at `deadline`.
struct AgentActivityTracker: Equatable, Sendable {
    /// An agent can crash or be killed without ever sending `done`.
    static let workingTimeout: TimeInterval = 10 * 60
    static let doneDuration: TimeInterval = 6
    /// Labels come from untrusted input; past this many the oldest agent is forgotten.
    static let maxAgents = 8

    struct Entry: Equatable, Sendable {
        /// Never `.idle`: an idle agent is removed.
        var activity: AgentActivity
        var deadline: Date?
        /// Event order; larger is more recent.
        var sequence: Int
        var source: AgentSource?
    }

    /// Keyed by sanitized label; `""` is the unlabeled agent.
    private(set) var agents: [String: Entry] = [:]
    private var sequence = 0

    /// The earliest moment any agent falls back to idle on its own.
    var deadline: Date? { agents.values.compactMap(\.deadline).min() }

    var summary: AgentActivitySummary {
        func note(_ key: String, _ message: String?) -> AgentActivitySummary.Note {
            .init(label: key.isEmpty ? nil : key, message: message, source: agents[key]?.source)
        }
        var summary = AgentActivitySummary()
        var waiting: [(key: String, message: String?, sequence: Int)] = []
        var done: [(key: String, message: String?, sequence: Int)] = []
        for (key, entry) in agents {
            switch entry.activity {
            case .working: summary.working = true
            case .waiting(let message): waiting.append((key, message, entry.sequence))
            case .done(let message): done.append((key, message, entry.sequence))
            case .idle: break   // never stored
            }
        }
        summary.done = done.max(by: { $0.sequence < $1.sequence }).map { note($0.key, $0.message) }
        if let latest = waiting.max(by: { $0.sequence < $1.sequence }) {
            summary.waiting = note(latest.key, latest.message)
            summary.otherWaitingCount = waiting.count - 1
        }
        return summary
    }

    /// The one activity the pet shows first: done, then waiting, then working.
    var activity: AgentActivity {
        let summary = summary
        if let done = summary.done { return .done(message: done.message) }
        if let waiting = summary.waiting { return .waiting(message: waiting.message) }
        return summary.working ? .working : .idle
    }

    /// An event replaces only its own label's state.
    mutating func apply(_ event: AgentActivityEvent, now: Date) {
        let key = event.label ?? ""
        expire(now: now)
        let deadline: Date?
        switch event.activity {
        case .idle:
            agents[key] = nil
            return
        case .working: deadline = now.addingTimeInterval(Self.workingTimeout)
        case .done: deadline = now.addingTimeInterval(Self.doneDuration)
        case .waiting: deadline = nil
        }
        if agents[key] == nil, agents.count >= Self.maxAgents,
           let oldest = agents.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            agents[oldest] = nil
        }
        sequence += 1
        // A hook that stops sending its source keeps the last one it sent.
        agents[key] = Entry(activity: event.activity, deadline: deadline, sequence: sequence,
                            source: event.source ?? agents[key]?.source)
    }

    /// Returns whether any agent changed.
    @discardableResult
    mutating func expire(now: Date) -> Bool {
        let before = agents.count
        agents = agents.filter { $0.value.deadline.map { now < $0 } ?? true }
        return agents.count != before
    }

    /// A click on the pet answers every question and acknowledges results; it does not stop work.
    @discardableResult
    mutating func dismissBubble() -> Bool {
        let before = agents.count
        agents = agents.filter { $0.value.activity == .working }
        return agents.count != before
    }

    mutating func reset() {
        agents = [:]
    }
}
