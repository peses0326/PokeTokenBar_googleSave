import Foundation

/// Bounded aggregates share one cache instead of scanning local transcript roots.
actor CloudUsageCache {
    static let shared = CloudUsageCache()
    static let maxBytes = 2 * 1024 * 1024
    let file: URL
    private var fingerprint: String?
    private var cached: [RemoteSummary] = []
    init(file: URL = AppStatePaths.directory().appendingPathComponent("cloud-usage.json")) { self.file = file }

    func load() throws -> [RemoteSummary] {
        guard FileManager.default.fileExists(atPath: file.path) else { fingerprint = nil; cached = []; return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Self.maxBytes + 1
        guard size <= Self.maxBytes else { throw CloudSyncError.message("Cloud usage exceeds 2 MiB") }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let key = "\(modified)/\(size)/\(attributes[.systemFileNumber] ?? "")"
        if fingerprint == key { return cached }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes else { throw CloudSyncError.message("Cloud usage exceeds 2 MiB") }
        struct Envelope: Decodable { let version: Int; let summaries: [RemoteSummary] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.summaries.count <= 32,
              Set(envelope.summaries.map(\.sourceId)).count == envelope.summaries.count else {
            throw CloudSyncError.message("Invalid or duplicate cloud usage sources")
        }
        var total = 0
        for summary in envelope.summaries {
            try RemoteSummaryCache.validate(summary, now: Date())
            for usage in summary.providers.values {
                total += usage.totalTokens
                guard total <= SaveTransfer.maxTokenValue else { throw CloudSyncError.message("Cloud totals exceed supported range") }
            }
        }
        cached = envelope.summaries; fingerprint = key
        return cached
    }
}

struct CloudUsageProvider: UsageProvider {
    var cache: CloudUsageCache = .shared
    var id: String { "cloud_usage" }
    var displayName: String { "Google Cloud Usage" }
    var reportsCost: Bool { false }

    func fetchDaily() async throws -> DailyUsage? {
        let sources = try await cache.load()
        guard !sources.isEmpty else { return nil }
        let today = LocalUsageReader.todayKey()
        let days = sources.flatMap { $0.providers.values.flatMap(\.days) }.filter { $0.date == today }
        var daily = DailyUsage(date: today, inputTokens: days.reduce(0) { $0 + $1.input },
            outputTokens: days.reduce(0) { $0 + $1.output }, cacheCreationTokens: days.reduce(0) { $0 + $1.cacheWrite },
            cacheReadTokens: days.reduce(0) { $0 + $1.cacheRead }, totalTokens: days.reduce(0) { $0 + $1.total },
            totalCost: 0, costCoverage: .unavailable)
        daily.growthCounters = sources.flatMap { source in source.providers.map { kind, usage in
            UsageGrowthCounter(sourceID: "\(source.sourceId)/\(kind)", totalTokens: usage.totalTokens)
        } }
        return daily
    }

    func fetchEnrichment() async -> ProviderEnrichment {
        do {
            let sources = try await cache.load()
            let formatter = LocalUsageReader.localDayFormatter()
            let entries = sources.flatMap { source in source.providers.flatMap { kind, usage in
                usage.days.compactMap { day -> LocalUsageReader.Entry? in
                    guard let date = formatter.date(from: day.date) else { return nil }
                    return LocalUsageReader.Entry(id: "\(source.sourceId)/\(kind)/\(day.date)", date: date,
                        localDay: day.date, model: "cloud", input: day.input, output: day.output,
                        cacheWrite: day.cacheWrite, cacheRead: day.cacheRead, costUnavailable: true)
                }
            } }
            var result = ProviderEnrichment.local(entries: entries)
            result.activeBlock = nil
            result.lastUsage = sources.flatMap { $0.providers.values }.compactMap(\.lastUsage)
                .compactMap { ISO8601Parser.date(from: $0) }.max()
            return result
        } catch { return ProviderEnrichment() }
    }
}
