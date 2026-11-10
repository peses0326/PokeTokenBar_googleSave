import Foundation

enum RemoteUsageKind: String, Sendable { case claude, codex }

struct RemoteSummary: Decodable, Sendable {
    struct Day: Decodable, Sendable {
        let date: String
        let input, output, cacheWrite, cacheRead: Int
        var total: Int { input + output + cacheWrite + cacheRead }
    }
    struct Usage: Decodable, Sendable {
        let totalTokens: Int
        let lastUsage: String?
        let days: [Day]
    }
    let version: Int
    let sourceId: String
    let timezone: String
    let generatedAt: String
    let providers: [String: Usage]
}

enum RemoteSummaryError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "Remote usage summary: \(reason)" }
    }
}

/// Deliberately does not use LocalAdditionalUsageCache: this is one bounded,
/// atomically replaced aggregate, not an append-only transcript collection. A shared
/// actor and (mtime, size, inode) fingerprint serve both providers and refresh phases.
actor RemoteSummaryCache {
    static let shared = RemoteSummaryCache()
    static let maxBytes = 256 * 1024
    private let file: URL
    private var fingerprint: String?
    private var cached: RemoteSummary?

    init(file: URL = AppStatePaths.directory().appendingPathComponent("remote-usage.json")) {
        self.file = file
    }

    func load(now: Date = Date()) throws -> RemoteSummary? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain &&
                (cocoa.code == NSFileNoSuchFileError || cocoa.code == NSFileReadNoSuchFileError) {
                fingerprint = nil; cached = nil
                return nil  // Not configured; no network request or background process.
            }
            throw error
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maxBytes else {
            throw RemoteSummaryError.invalid("file exceeds 256 KiB")
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let key = "\(modified)/\(size)/\(attributes[.systemFileNumber] ?? "")"
        if fingerprint == key, let cached {
            try Self.validate(cached, now: now)
            return cached
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes else { throw RemoteSummaryError.invalid("file exceeds 256 KiB") }
        let summary = try JSONDecoder().decode(RemoteSummary.self, from: data)
        try Self.validate(summary, now: now)
        cached = summary
        fingerprint = key
        return summary
    }

    static func validate(_ summary: RemoteSummary, now: Date) throws {
        guard summary.version == 1, UUID(uuidString: summary.sourceId) != nil,
              TimeZone(identifier: summary.timezone) != nil,
              let generated = ISO8601Parser.date(from: summary.generatedAt),
              generated <= now.addingTimeInterval(300) else {
            throw RemoteSummaryError.invalid("unsupported version, source ID, timezone or timestamp")
        }
        // Daily totals cannot be rebucketed after the server has discarded timestamps.
        guard summary.timezone == TimeZone.current.identifier else {
            throw RemoteSummaryError.invalid("server timezone must match Mac timezone (\(TimeZone.current.identifier))")
        }
        guard Set(summary.providers.keys) == ["claude", "codex"] else {
            throw RemoteSummaryError.invalid("expected claude and codex totals")
        }
        let formatter = LocalUsageReader.localDayFormatter()
        let generatedDay = formatter.string(from: generated)
        for usage in summary.providers.values {
            guard (0...SaveTransfer.maxTokenValue).contains(usage.totalTokens), usage.days.count <= 62 else {
                throw RemoteSummaryError.invalid("invalid cumulative total or day count")
            }
            var seen = Set<String>()
            var subtotal = 0
            for day in usage.days {
                let counts = [day.input, day.output, day.cacheWrite, day.cacheRead]
                guard counts.allSatisfy({ (0...SaveTransfer.maxTokenValue).contains($0) }),
                      day.date.count == 10, let date = formatter.date(from: day.date),
                      formatter.string(from: date) == day.date, day.date <= generatedDay,
                      seen.insert(day.date).inserted else {
                    throw RemoteSummaryError.invalid("invalid or duplicate daily record")
                }
                subtotal += day.total
                guard subtotal <= usage.totalTokens else {
                    throw RemoteSummaryError.invalid("daily totals exceed cumulative total")
                }
            }
            if let stamp = usage.lastUsage {
                guard let last = ISO8601Parser.date(from: stamp), last <= generated.addingTimeInterval(300) else {
                    throw RemoteSummaryError.invalid("invalid last usage timestamp")
                }
            }
        }
    }
}

struct RemoteSummaryProvider: UsageProvider {
    let kind: RemoteUsageKind
    var cache: RemoteSummaryCache = .shared
    var id: String { "remote_\(kind.rawValue)" }
    var displayName: String { kind == .claude ? "Server Claude" : "Server Codex" }
    var reportsCost: Bool { false }

    func fetchDaily() async throws -> DailyUsage? {
        guard let summary = try await cache.load(), let usage = summary.providers[kind.rawValue] else { return nil }
        let today = LocalUsageReader.todayKey()
        let day = usage.days.first { $0.date == today }
        return DailyUsage(date: today, inputTokens: day?.input ?? 0, outputTokens: day?.output ?? 0,
                          cacheCreationTokens: day?.cacheWrite ?? 0, cacheReadTokens: day?.cacheRead ?? 0,
                          totalTokens: day?.total ?? 0, totalCost: 0, costCoverage: .unavailable,
                          growthCounter: UsageGrowthCounter(sourceID: "\(summary.sourceId)/\(kind.rawValue)",
                                                            totalTokens: usage.totalTokens))
    }

    func fetchEnrichment() async -> ProviderEnrichment {
        do {
            guard let summary = try await cache.load(), let usage = summary.providers[kind.rawValue] else {
                return ProviderEnrichment(blocksOK: true, periodsOK: true)
            }
            let formatter = LocalUsageReader.localDayFormatter()
            let entries = usage.days.compactMap { day -> LocalUsageReader.Entry? in
                guard let date = formatter.date(from: day.date) else { return nil }
                return LocalUsageReader.Entry(id: "\(id)/\(day.date)", date: date, localDay: day.date,
                                              model: "remote", input: day.input, output: day.output,
                                              cacheWrite: day.cacheWrite, cacheRead: day.cacheRead,
                                              costUnavailable: true)
            }
            var result = ProviderEnrichment.local(entries: entries)
            // A daily aggregate cannot substantiate a live burn rate or block.
            result.activeBlock = nil
            result.lastUsage = usage.lastUsage.flatMap { ISO8601Parser.date(from: $0) }
            return result
        } catch {
            return ProviderEnrichment()  // Preserve previous enrichment on invalid input.
        }
    }
}
