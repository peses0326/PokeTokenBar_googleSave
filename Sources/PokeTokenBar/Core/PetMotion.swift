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
    /// Settings levels for frequency and radius: 1 calm … 5 lively. 2 is the original pace.
    static let levels: ClosedRange<Int> = 1...5
    static let defaultLevel = 2

    static func clampedLevel(_ level: Int) -> Int { min(max(level, levels.lowerBound), levels.upperBound) }

    /// Pause between two idle motions per frequency level. Even the liveliest level sleeps over a
    /// second between motions, so the loop never becomes a busy loop.
    static func delayRange(level: Int = defaultLevel) -> ClosedRange<Double> {
        switch clampedLevel(level) {
        case 1: return 15...35
        case 2: return 8...20
        case 3: return 5...12
        case 4: return 3...7
        default: return 1.5...4
        }
    }

    /// Wander radius in pet widths per radius level.
    static func radiusFactor(level: Int = defaultLevel) -> CGFloat {
        switch clampedLevel(level) {
        case 1: return 0.75
        case 2: return 1.5
        case 3: return 2.5
        case 4: return 4
        default: return 6
        }
    }

    /// Motions to cycle through, or empty when nothing should run. Agent bobbing owns the sprite,
    /// and motion stays off for Reduce Motion / Low Power (`motionAllowed`).
    static func activeMotions(autoMotion: Bool, enabled: Set<PetMotion>, motionAllowed: Bool,
                              bobbing: Bool) -> [PetMotion] {
        guard autoMotion, motionAllowed, !bobbing else { return [] }
        return PetMotion.allCases.filter(enabled.contains)
    }

    static func nextDelay(unit: Double, level: Int = defaultLevel) -> Double {
        let range = delayRange(level: level)
        let u = min(max(unit, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * u
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
    static func wanderRadius(petSize: CGFloat, level: Int = defaultLevel) -> CGFloat {
        petSize * radiusFactor(level: level)
    }

    /// Steps grow with the radius, so a wide range is actually explored rather than inched across.
    static func stepScale(level: Int) -> CGFloat { radiusFactor(level: level) / radiusFactor(level: defaultLevel) }

    /// Next horizontal offset from home for a walk. Steps 0.4–1.0 pet widths (× `stepScale`) in the preferred
    /// direction, turns around when that would leave the radius or the screen, and always ends
    /// inside both. `homeX` is the pet's left edge at home.
    static func wanderTarget(current: CGFloat, petSize: CGFloat, homeX: CGFloat,
                             visibleMinX: CGFloat, visibleMaxX: CGFloat,
                             goRight: Bool, unit: Double, level: Int = defaultLevel) -> CGFloat {
        let radius = wanderRadius(petSize: petSize, level: level)
        let lower = max(-radius, visibleMinX - homeX)
        let upper = min(radius, visibleMaxX - petSize - homeX)
        guard lower < upper else { return 0 }   // no room: stay home
        let step = petSize * (0.4 + 0.6 * CGFloat(min(max(unit, 0), 1))) * stepScale(level: level)
        var target = current + (goRight ? step : -step)
        if target > upper || target < lower { target = current + (goRight ? -step : step) }
        return min(max(target, lower), upper)
    }

    /// Walk time for a distance: about 0.8 pet widths a second at level 2, a bit quicker on wider
    /// levels so a long walk does not crawl; never a blink.
    static func walkDuration(distance: CGFloat, petSize: CGFloat, level: Int = defaultLevel) -> Double {
        let speed = petSize * 0.8 * stepScale(level: level).squareRoot()
        return max(0.6, Double(abs(distance) / max(speed, 1)))
    }
}

/// One idle motion the controller asks the pet view to play. `seq` makes a repeat a new cue.
struct PetMotionCue: Equatable, Sendable {
    var seq: Int
    var motion: PetMotion
    var goesRight = false
    var duration: Double = 0
}
