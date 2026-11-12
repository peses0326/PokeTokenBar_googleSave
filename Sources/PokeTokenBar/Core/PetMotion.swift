import Foundation

/// One-shot idle motions the floating pet plays now and then on its own (Settings → Floating Pet →
/// Auto motion). Each is a short transform of the existing sprite — no extra art is fetched.
enum PetMotion: String, CaseIterable, Identifiable, Sendable {
    /// Small jump. The panel grows upward for the jump, so the sprite never clips.
    case hop
    /// Walks a short way left or right around its home spot, facing the way it goes.
    case walk
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

    /// Extra panel height (pt) above the sprite while a hop plays. The jump itself is
    /// `hopHeight`; the rest covers the take-off stretch.
    static func hopHeadroom(petSize: CGFloat) -> CGFloat { (petSize * 0.25).rounded(.up) }
    static func hopHeight(petSize: CGFloat) -> CGFloat { petSize * 0.18 }

    /// How far (pt) the pet may stray from the home the user dragged it to.
    static func wanderRadius(petSize: CGFloat) -> CGFloat { petSize * 1.5 }

    /// Next horizontal offset from home for a walk. Steps 0.4–1.0 pet widths in the preferred
    /// direction, turns around when that would leave the radius or the screen, and always ends
    /// inside both. `homeX` is the pet's left edge at home.
    static func wanderTarget(current: CGFloat, petSize: CGFloat, homeX: CGFloat,
                             visibleMinX: CGFloat, visibleMaxX: CGFloat,
                             goRight: Bool, unit: Double) -> CGFloat {
        let radius = wanderRadius(petSize: petSize)
        let lower = max(-radius, visibleMinX - homeX)
        let upper = min(radius, visibleMaxX - petSize - homeX)
        guard lower < upper else { return 0 }   // no room: stay home
        let step = petSize * (0.4 + 0.6 * CGFloat(min(max(unit, 0), 1)))
        var target = current + (goRight ? step : -step)
        if target > upper || target < lower { target = current + (goRight ? -step : step) }
        return min(max(target, lower), upper)
    }

    /// Walk time for a distance: about 0.8 pet widths a second, never a blink.
    static func walkDuration(distance: CGFloat, petSize: CGFloat) -> Double {
        max(0.6, Double(abs(distance) / max(petSize * 0.8, 1)))
    }
}

/// One idle motion the controller asks the pet view to play. `seq` makes a repeat a new cue.
struct PetMotionCue: Equatable, Sendable {
    var seq: Int
    var motion: PetMotion
    var goesRight = false
    var duration: Double = 0
}
