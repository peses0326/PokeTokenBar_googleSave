import Foundation

/// One other computer's daily token totals, read from its usage file in the Drive save folder.
/// Written by `ptb push` on Linux servers (or any machine running the helper), never by this Mac:
/// a Mac credits its own logs directly and its growth travels inside the save.
struct RemoteDeviceUsage: Decodable, Sendable, Equatable {
    let device: String
    let deviceName: String
    var updatedAt: String?
    /// day (`yyyy-MM-dd`, in the timezone the device was told to use) → provider → tokens
    let days: [String: [String: Int]]

    func tokens(on day: String) -> Int { days[day]?.values.reduce(0, +) ?? 0 }
}

/// How far this save has credited each remote device, per day. Part of the synced save — not a
/// per-Mac ledger — so a second Mac that downloads the save does not credit the same server tokens
/// again. Keyed by the remote device id.
struct RemoteUsageLedger: Codable, Sendable, Equatable {
    /// The day the device was first seen. Days up to it were seeded, never credited:
    /// like a newly observed local provider, history from before the link is not paid out.
    var seededThrough: String
    var claimed: [String: Int]
}

enum RemoteUsageCredit {
    /// Days older than `today - window + 1` are ignored. Two extra days cover a server that uploads
    /// its last pre-midnight usage after this Mac's date has already changed.
    static let windowDays = 3
    static let maxDevices = 32
    static let maxDayTokens = 10_000_000_000_000

    /// Drops devices and values the helper should already have rejected — the file is written by any
    /// computer signed in to the account, so the app checks again at its own boundary.
    static func validated(_ devices: [RemoteDeviceUsage]) -> [RemoteDeviceUsage] {
        var seen = Set<String>()
        return devices.filter { device in
            guard UUID(uuidString: device.device) != nil, seen.insert(device.device.lowercased()).inserted else { return false }
            return device.days.allSatisfy { day, providers in
                isDay(day) && providers.values.allSatisfy { (0...maxDayTokens).contains($0) }
            }
        }.prefix(maxDevices).map { $0 }
    }

    /// Credits what each device used since the last credit and returns the total to grow by.
    /// The ledger is updated in place: seeded on first sight, rebased when a total goes down,
    /// and pruned to the window.
    static func apply(_ devices: [RemoteDeviceUsage], ledger: inout [String: RemoteUsageLedger],
                      todayDate: String) -> Int {
        guard isDay(todayDate) else { return 0 }
        let windowStart = day(todayDate, offset: -(windowDays - 1))
        var delta = 0
        for device in validated(devices) {
            let key = device.device.lowercased()
            let days = device.days.keys.filter { $0 >= windowStart && $0 <= todayDate }
            guard var entry = ledger[key] else {
                // Today is always recorded, even at 0, so usage later today counts.
                var claimed = Dictionary(uniqueKeysWithValues: days.map { ($0, device.tokens(on: $0)) })
                claimed[todayDate] = device.tokens(on: todayDate)
                ledger[key] = RemoteUsageLedger(seededThrough: todayDate, claimed: claimed)
                continue
            }
            for day in days {
                let total = device.tokens(on: day)
                guard let claimed = entry.claimed[day] else {
                    // A day first reported after the device was seeded is new usage; an older day
                    // that only now appears is history and is seeded.
                    if day > entry.seededThrough { delta += total }
                    entry.claimed[day] = total
                    continue
                }
                if total > claimed { delta += total - claimed }
                entry.claimed[day] = total   // a lower total (logs pruned, reinstall) rebases
            }
            entry.claimed = entry.claimed.filter { $0.key >= windowStart }
            ledger[key] = entry
        }
        return min(delta, maxDayTokens)
    }

    /// Two saves' ledgers combined so importing an older save cannot credit the same tokens twice.
    static func merged(_ a: [String: RemoteUsageLedger], _ b: [String: RemoteUsageLedger]) -> [String: RemoteUsageLedger] {
        a.merging(b) { x, y in
            RemoteUsageLedger(seededThrough: max(x.seededThrough, y.seededThrough),
                              claimed: x.claimed.merging(y.claimed, uniquingKeysWith: max))
        }
    }

    static func isDay(_ value: String) -> Bool {
        value.count == 10 && formatter().date(from: value) != nil
    }

    static func day(_ value: String, offset: Int) -> String {
        let f = formatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = f.timeZone
        guard let date = f.date(from: value),
              let shifted = calendar.date(byAdding: .day, value: offset, to: date) else { return value }
        return f.string(from: shifted)
    }

    /// Day keys are plain calendar dates; UTC arithmetic keeps DST from skipping or repeating one.
    private static func formatter() -> DateFormatter {
        LocalUsageReader.localDayFormatter(timeZone: TimeZone(identifier: "UTC")!)
    }
}
