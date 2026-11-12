import SwiftUI

/// Plays the idle motion the controller cues. The controller owns the schedule (one coalesced
/// timer) and the panel: it grows the panel before a hop and moves it during a walk, so this view
/// only animates the sprite inside. No cue, no work. The state lives here so a motion step re-runs
/// only this modifier, not the pet's body.
@MainActor
struct PetIdleMotion: ViewModifier {
    let cue: PetMotionCue?
    let petSize: CGFloat
    /// Back sprites face the other way, so a walk must flip the opposite way.
    let facesBack: Bool

    private struct Pose: Equatable {
        var offsetY: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0
        var flipped = false
    }

    @State private var pose = Pose()

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: (pose.flipped ? -1 : 1) * pose.scaleX, y: pose.scaleY, anchor: .bottom)
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(y: pose.offsetY)
            .task(id: cue?.seq) {
                pose = Pose()
                guard let cue else { return }
                await play(cue)
                pose = Pose()
            }
    }

    /// Front sprites face the viewer's left, back sprites the right.
    static func flipsForWalk(goesRight: Bool, facesBack: Bool) -> Bool { goesRight != facesBack }

    private func play(_ cue: PetMotionCue) async {
        switch cue.motion {
        case .hop:
            let height = PetMotionSchedule.hopHeight(petSize: petSize)
            await step(0.08, .easeOut) { $0.scaleX = 1.06; $0.scaleY = 0.9 }
            await step(0.18, .easeOut) { $0.scaleX = 0.96; $0.scaleY = 1.04; $0.offsetY = -height }
            await step(0.18, .easeIn) { $0.scaleX = 1; $0.scaleY = 1; $0.offsetY = 0 }
            await step(0.08, .easeOut) { $0.scaleX = 1.06; $0.scaleY = 0.92 }
            await step(0.1, .easeOut) { $0.scaleX = 1; $0.scaleY = 1 }
        case .walk:
            pose.flipped = Self.flipsForWalk(goesRight: cue.goesRight, facesBack: facesBack)
            // Little steps while the panel slides: squash on each footfall.
            let stride = 0.16
            var elapsed = 0.0
            while elapsed < cue.duration, !Task.isCancelled {
                await step(stride / 2, .easeOut) { $0.scaleY = 0.95; $0.rotation = $0.rotation >= 0 ? -2 : 2 }
                await step(stride / 2, .easeIn) { $0.scaleY = 1 }
                elapsed += stride
            }
            await step(0.1, .easeOut) { $0.rotation = 0 }
            try? await Task.sleep(for: .seconds(0.6))
        case .lookAround:
            await step(0.12, .easeInOut) { $0.scaleX = 0.05 }
            await step(0.12, .easeInOut) { $0.flipped = true; $0.scaleX = 1 }
            try? await Task.sleep(for: .seconds(1.2))
            await step(0.12, .easeInOut) { $0.scaleX = 0.05 }
            await step(0.12, .easeInOut) { $0.flipped = false; $0.scaleX = 1 }
        case .wiggle:
            for angle in [-7.0, 7, -5, 5, -2, 0] {
                await step(0.07, .linear) { $0.rotation = angle }
            }
        case .bounce:
            for _ in 0..<3 {
                await step(0.12, .easeOut) { $0.scaleX = 1.05; $0.scaleY = 0.9 }
                await step(0.14, .easeInOut) { $0.scaleX = 1; $0.scaleY = 1 }
            }
        case .sway:
            await step(0.45, .easeInOut) { $0.rotation = -6 }
            await step(0.6, .easeInOut) { $0.rotation = 6 }
            await step(0.45, .easeInOut) { $0.rotation = 0 }
        }
    }

    private enum Curve { case linear, easeIn, easeOut, easeInOut }

    private func step(_ duration: Double, _ curve: Curve, _ change: (inout Pose) -> Void) async {
        guard !Task.isCancelled else { return }
        let animation: Animation
        switch curve {
        case .linear: animation = .linear(duration: duration)
        case .easeIn: animation = .easeIn(duration: duration)
        case .easeOut: animation = .easeOut(duration: duration)
        case .easeInOut: animation = .easeInOut(duration: duration)
        }
        var next = pose
        change(&next)
        withAnimation(animation) { pose = next }
        try? await Task.sleep(for: .seconds(duration))
    }
}
