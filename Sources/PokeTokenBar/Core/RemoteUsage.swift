import Foundation

/// One other computer's usage, read from its usage file in the Drive save folder.
/// Written by `ptb push` on Linux servers (or any machine without the app), never by a Mac:
/// a Mac credits its own logs directly and its growth travels inside the save.
struct RemoteDeviceUsage: Decodable, Sendable, Equatable {
    let device: String
    let deviceName: String
    var updatedAt: String?
    /// day (`yyyy-MM-dd`, in the timezone the device was told to use) → provider → tokens. Display only.
    let days: [String: [String: Int]]
    /// provider → tokens counted since the device's collector started. Growth is credited from this,
    /// so a gap of any length between syncs is still counted in full. Nil from a pre-total `ptb`.
    var total: [String: Int]?

    func tokens(on day: String) -> Int { days[day]?.values.reduce(0, +) ?? 0 }
    var lifetimeTokens: Int? { total.map { $0.values.reduce(0, +) } }
}

/// How much of each remote device's lifetime total this save has already credited. Part of the
/// synced save — not a per-Mac ledger — so a second Mac that downloads the save does not credit
/// the same server tokens again. Keyed by the remote device id.
struct RemoteUsageLedger: Codable, Sendable, Equatable {
    var claimedTotal: Int
}

enum RemoteUsageCredit {
    static let maxDevices = 32
    static let maxDayTokens = 10_000_000_000_000
    static let maxTotalTokens = 1_000_000_000_000_000

    /// Drops devices and values the helper should already have rejected — the file is written by any
    /// computer signed in to the account, so the app checks again at its own boundary.
    static func validated(_ devices: [RemoteDeviceUsage]) -> [RemoteDeviceUsage] {
        var seen = Set<String>()
        return devices.filter { device in
            guard UUID(uuidString: device.device) != nil, seen.insert(device.device.lowercased()).inserted else { return false }
            let daysOK = device.days.allSatisfy { day, providers in
                isDay(day) && providers.values.allSatisfy { (0...maxDayTokens).contains($0) }
            }
            let totalOK = device.total?.values.allSatisfy { (0...maxTotalTokens).contains($0) } ?? true
            return daysOK && totalOK
        }.prefix(maxDevices).map { $0 }
    }

    /// Credits what each device used since the last credit — however long ago that was — and returns
    /// the total to grow by. The ledger is updated in place: seeded on first sight (history from before
    /// the link is not paid out, like a newly observed local provider) and rebased when a total goes
    /// down (the device's collector was reset).
    static func apply(_ devices: [RemoteDeviceUsage], ledger: inout [String: RemoteUsageLedger]) -> Int {
        var delta = 0
        for device in validated(devices) {
            guard let total = device.lifetimeTokens else { continue }   // pre-total ptb: display only
            let key = device.device.lowercased()
            if let claimed = ledger[key]?.claimedTotal, total > claimed {
                delta += total - claimed
            }
            ledger[key] = RemoteUsageLedger(claimedTotal: total)
        }
        return min(delta, maxTotalTokens)
    }

    /// Two saves' ledgers combined so importing an older save cannot credit the same tokens twice.
    static func merged(_ a: [String: RemoteUsageLedger], _ b: [String: RemoteUsageLedger]) -> [String: RemoteUsageLedger] {
        a.merging(b) { RemoteUsageLedger(claimedTotal: max($0.claimedTotal, $1.claimedTotal)) }
    }

    static func isDay(_ value: String) -> Bool {
        value.count == 10 && LocalUsageReader.localDayFormatter(timeZone: TimeZone(identifier: "UTC")!).date(from: value) != nil
    }
}
