import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Renders the floating pet with an agent "done" bubble at several pet sizes, fonts and colors.
/// **Skipped unless `PTB_BUBBLE_RENDER_DIR` names a directory:**
///
///     PTB_BUBBLE_RENDER_DIR=/some/dir swift test --filter SpeechBubbleRenderTests
///
/// The sprite is a generated placeholder in a throwaway `SpriteStore`, so nothing is downloaded.
@MainActor
final class SpeechBubbleRenderTests: XCTestCase {
    private static let speciesID = 25
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
    }

    private final class ClockBox: @unchecked Sendable {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    func testRenderBubbleAcrossPetSizesFontsAndColors() async throws {
        guard let path = ProcessInfo.processInfo.environment["PTB_BUBBLE_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("PTB_BUBBLE_RENDER_DIR not set — render only when asked")
        }
        let directory = URL(fileURLWithPath: path)
        let spriteDir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-render-\(UUID())")
        try FileManager.default.createDirectory(at: spriteDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: spriteDir) }
        // A generated stand-in, never downloaded Pokémon artwork, so the renders can go in a PR.
        // Its top 30% is empty canvas, like most sprites, so the tail anchor is exercised.
        let key = SpriteStore.cacheKey(speciesID: Self.speciesID, animated: false, shiny: false, back: false)
        try placeholderPNG().write(to: spriteDir.appendingPathComponent(key + ".png"))
        let sprites = SpriteStore(directory: spriteDir)

        let cases: [(name: String, pet: Double, scale: Double, font: BubbleFontDesign, theme: BubbleColorTheme, dark: Bool)] = [
            ("pet64-dark", 64, 1, .system, .system, true),
            ("pet96-dark", 96, 1, .system, .system, true),
            ("pet192-dark", 192, 1, .system, .system, true),
            ("pet288-dark", 288, 1, .system, .system, true),
            ("pet96-light", 96, 1, .system, .system, false),
            ("pet128-rounded-cream", 128, 1.2, .rounded, .cream, true),
            ("pet128-serif-sky", 128, 1, .serif, .sky, false),
            ("pet128-mono-night", 128, 1, .monospaced, .night, false),
        ]
        for c in cases {
            let companion = try await makeCompanion()
            let suite = "BubbleRender-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            let usage = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
            usage.floatingPetSize = c.pet
            usage.floatingPetBubbleFontScale = c.scale
            usage.floatingPetBubbleFont = c.font
            usage.floatingPetBubbleTheme = c.theme
            let agent = FloatingPetAgentModel()
            agent.summary = AgentActivitySummary(done: .init(label: "PokeTokenBar", message: "Tests pass — the bubble now follows the pet size"))
            let panel = FloatingPetController.panelSize(petSize: CGFloat(c.pet), showingBubble: true,
                                                        style: usage.speechBubbleStyle)
            let view = FloatingPetView(animated: false, agent: agent, spriteStore: sprites)
                .environment(usage).environment(companion)
                .frame(width: panel.width, height: panel.height)
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, c.dark ? .dark : .light)))
            let size = NSSize(width: panel.width + 40, height: panel.height + 40)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: c.dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            windows.append(window)
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("bubble-\(c.name).png"))
            print("wrote bubble-\(c.name).png body=\(usage.speechBubbleStyle.bodySize)pt panel=\(panel)")
        }
    }

    private func placeholderPNG() throws -> Data {
        let side = 96
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 6, width: 52, height: 58), xRadius: 18, yRadius: 18).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 34, y: 40, width: 8, height: 8)).fill()
        NSBezierPath(ovalIn: NSRect(x: 54, y: 40, width: 8, height: 8)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func makeCompanion() async throws -> CompanionStore {
        let clock = ClockBox()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-render-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let suite = "BubbleRenderCompanion-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let names = [Self.speciesID: ["en": "Pikachu", "ko": "피카츄"]]
        let line = EvoLine(baseID: Self.speciesID, tree: EvoNode(speciesID: Self.speciesID, children: []),
                           rarity: .common, names: names)
        let store = CompanionStore(provider: StubProvider(value: line), clock: { clock.now },
                                   fileURL: file, rng: SeededRNG(seed: 5), defaults: defaults)
        store.setLanguage(.en)
        await store.hatch(baseID: Self.speciesID)
        return store
    }
}
