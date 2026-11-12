import Foundation

/// One-shot idle motions the floating pet plays now and then on its own (Settings → Floating Pet →
/// Auto motion). Each is a short transform of the existing sprite — no extra art is fetched.
enum PetMotion: String, CaseIterable, Identifiable, Sendable {
    /// Small jump, capped by the empty space above the sprite so it never clips the panel.
    case hop
    /// Faces the other way for a moment, then turns back.
    case lookAround
    /// Quick side-to-side shake.
    case wiggle
    /// Three squashes toward the feet.
    case bounce
    /// Slow lean left and right from the feet.
    case sway

    var id: String { rawValue }

    /// Stored order of the enabled set; unknown raw values (from a newer build) are dropped.
    static func decode(_ raw: [String]?) -> Set<PetMotion> {
        guard let raw else { return Set(allCases) }
        return Set(raw.compactMap(PetMotion.init(rawValue:)))
    }

    static func encode(_ motions: Set<PetMotion>) -> [String] {
        allCases.filter(motions.contains).map(\.rawValue)
    }
}

/// Pure scheduling rules for the idle motions, kept out of SwiftUI so tests can pin them.
enum PetMotionSchedule {
    /// Pause between two idle motions. Long enough that the loop is mostly asleep (a wakeup every
    /// 8–20 s), short enough that the pet visibly lives.
    static let delayRange: ClosedRange<Double> = 8...20

    /// Motions to cycle through, or empty when nothing should run. Agent bobbing owns the sprite,
    /// and motion stays off for Reduce Motion / Low Power (`motionAllowed`).
    static func activeMotions(autoMotion: Bool, enabled: Set<PetMotion>, motionAllowed: Bool,
                              bobbing: Bool) -> [PetMotion] {
        guard autoMotion, motionAllowed, !bobbing else { return [] }
        return PetMotion.allCases.filter(enabled.contains)
    }

    static func nextDelay(unit: Double) -> Double {
        let u = min(max(unit, 0), 1)
        return delayRange.lowerBound + (delayRange.upperBound - delayRange.lowerBound) * u
    }

    /// A random enabled motion, avoiding an immediate repeat when there is a choice.
    static func pick(from motions: [PetMotion], previous: PetMotion?, index: Int) -> PetMotion? {
        guard !motions.isEmpty else { return nil }
        let pool = motions.count > 1 ? motions.filter { $0 != previous } : motions
        return pool[abs(index) % pool.count]
    }

    /// Hop height (pt): 12% of the pet, but never more than the transparent rows above the
    /// sprite, because the panel is exactly sprite-tall and would clip a taller jump.
    static func hopHeight(petSize: CGFloat, visibleTop: CGFloat?) -> CGFloat {
        let wanted = petSize * 0.12
        guard let visibleTop else { return 0 }
        return max(0, min(wanted, visibleTop))
    }
}
