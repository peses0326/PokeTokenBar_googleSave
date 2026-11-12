import SwiftUI

/// Plays one `PetMotion` every `PetMotionSchedule.delayRange` seconds while `motions` is non-empty.
/// Between motions the loop only sleeps (coalesced), so the idle cost is one wakeup per 8–20 s;
/// an empty list cancels the loop, as `AgentBob` does. The state lives here so a motion step
/// re-runs only this modifier, not the pet's body.
@MainActor
struct PetIdleMotion: ViewModifier {
    let motions: [PetMotion]
    let petSize: CGFloat

    private struct Pose: Equatable {
        var offsetY: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0
        var flipped = false
    }

    @State private var pose = Pose()
    @State private var visibleTop: CGFloat?

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: (pose.flipped ? -1 : 1) * pose.scaleX, y: pose.scaleY, anchor: .bottom)
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(y: pose.offsetY)
            .onPreferenceChange(SpriteVisibleTopKey.self) { visibleTop = $0 }
            .task(id: motions) {
                pose = Pose()
                guard !motions.isEmpty else { return }
                var previous: PetMotion?
                while !Task.isCancelled {
                    let delay = PetMotionSchedule.nextDelay(unit: .random(in: 0...1))
                    try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
                    guard !Task.isCancelled,
                          let motion = PetMotionSchedule.pick(from: motions, previous: previous,
                                                              index: .random(in: 0..<64))
                    else { return }
                    previous = motion
                    await play(motion)
                    pose = Pose()
                }
            }
    }

    /// Animates `pose` through the motion's steps, then leaves it at rest.
    private func play(_ motion: PetMotion) async {
        switch motion {
        case .hop:
            let height = PetMotionSchedule.hopHeight(petSize: petSize, visibleTop: visibleTop)
            await step(0.08, .easeOut) { $0.scaleX = 1.06; $0.scaleY = 0.9 }
            await step(0.18, .easeOut) { $0.scaleX = 0.96; $0.scaleY = 1.04; $0.offsetY = -height }
            await step(0.18, .easeIn) { $0.scaleX = 1; $0.scaleY = 1; $0.offsetY = 0 }
            await step(0.08, .easeOut) { $0.scaleX = 1.06; $0.scaleY = 0.92 }
            await step(0.1, .easeOut) { $0.scaleX = 1; $0.scaleY = 1 }
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
