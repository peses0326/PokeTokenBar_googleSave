import AppKit
import SwiftUI

/// Typeface family of the floating pet's speech bubble. Each case is a system font design,
/// so the AppKit measurement and the SwiftUI view always draw the same glyphs.
enum BubbleFontDesign: String, CaseIterable, Identifiable, Sendable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var swiftUI: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    var appKit: NSFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// Color preset of the speech bubble. `system` follows light/dark mode; the others are fixed
/// palettes chosen so title and body text stay readable on their own background.
enum BubbleColorTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case cream
    case mint
    case sky
    case pink
    case night

    var id: String { rawValue }

    struct Palette {
        var background: NSColor
        var border: NSColor
        var title: NSColor
        var body: NSColor
        var critical: NSColor
    }

    var palette: Palette {
        switch self {
        case .system:
            return Palette(background: .windowBackgroundColor, border: .secondaryLabelColor,
                           title: .labelColor, body: .secondaryLabelColor, critical: .systemRed)
        case .cream:
            return Self.fixed(background: 0xFFF6D8, border: 0x9A7B45, title: 0x3B2F1E, body: 0x6B5A3E)
        case .mint:
            return Self.fixed(background: 0xE3F6EC, border: 0x2E8B66, title: 0x12402E, body: 0x3E6B58)
        case .sky:
            return Self.fixed(background: 0xE4F0FF, border: 0x3A6FB0, title: 0x13304F, body: 0x3F5F80)
        case .pink:
            return Self.fixed(background: 0xFFE6EF, border: 0xC2557F, title: 0x4A1830, body: 0x7A4560)
        case .night:
            return Self.fixed(background: 0x1F2333, border: 0x8A93B8, title: 0xF2F4FF, body: 0xB9C0DA,
                              critical: 0xFF6B6B)
        }
    }

    /// Swatch shown next to the theme name in Settings.
    var swatch: NSColor { palette.background }

    private static func fixed(background: UInt32, border: UInt32, title: UInt32, body: UInt32,
                              critical: UInt32 = 0xC62828) -> Palette {
        Palette(background: rgb(background), border: rgb(border), title: rgb(title), body: rgb(body),
                critical: rgb(critical))
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Everything that sizes and paints the speech bubble. The measurement (`measureSpeechBubbleLayout`),
/// the panel headroom and the view all read the same style, so the bubble grows with its font
/// instead of clipping. `standard` (10 pt body) reproduces the original fixed layout exactly.
struct SpeechBubbleStyle: Equatable, Sendable {
    /// Smallest body size; pets up to `autoBasePetSize` always get this.
    static let minimumBodySize: CGFloat = 10
    /// Pet edge (pt) up to which the automatic size stays at the minimum.
    static let autoBasePetSize: CGFloat = 90
    /// Pet points per extra body point above `autoBasePetSize` (90 → 10 pt, 192 → 13.5 pt, 384 → 20 pt).
    static let autoPetPointsPerFontPoint: CGFloat = 30
    /// User multiplier range for Settings.
    static let fontScaleRange: ClosedRange<Double> = 0.8...1.6

    var bodySize: CGFloat
    var design: BubbleFontDesign
    var theme: BubbleColorTheme

    static let standard = SpeechBubbleStyle(bodySize: minimumBodySize, design: .system, theme: .system)

    init(bodySize: CGFloat, design: BubbleFontDesign = .system, theme: BubbleColorTheme = .system) {
        self.bodySize = max(Self.minimumBodySize, bodySize)
        self.design = design
        self.theme = theme
    }

    /// Size that follows the pet, scaled by the user's multiplier, never below the minimum.
    init(petSize: CGFloat, fontScale: Double = 1, design: BubbleFontDesign = .system,
         theme: BubbleColorTheme = .system) {
        let scale = min(max(fontScale, Self.fontScaleRange.lowerBound), Self.fontScaleRange.upperBound)
        let raw = Self.autoBodySize(petSize: petSize) * CGFloat(scale)
        self.init(bodySize: (raw * 2).rounded() / 2, design: design, theme: theme)
    }

    static func autoBodySize(petSize: CGFloat) -> CGFloat {
        minimumBodySize + max(0, petSize - autoBasePetSize) / autoPetPointsPerFontPoint
    }

    /// Chrome scale relative to the original 10 pt layout.
    var scale: CGFloat { bodySize / Self.minimumBodySize }
    var titleSize: CGFloat { bodySize + 1 }
    var titleSpacing: CGFloat { 2 * scale }
    var horizontalPadding: CGFloat { 8 * scale }
    var verticalPadding: CGFloat { 6 * scale }
    var cornerRadius: CGFloat { 12 * scale }
    /// Fixed text column — copy wraps instead of growing past the panel.
    var contentWidth: CGFloat { 164 * scale }
    /// Bubble (and panel) width while a bubble shows: content + 2× padding.
    var minWidth: CGFloat { ceil(contentWidth + horizontalPadding * 2) }
    /// Height the bubble reserves under itself for the tail.
    var tailBase: CGFloat { 6 * scale }
    var tailWidth: CGFloat { 12 * scale }
    /// How much longer than `tailBase` the tail may grow toward the sprite.
    var tailReach: CGFloat { 8 * scale }
    /// Vertical space above the sprite for the bubble + VStack spacing. Sized for two wrapped
    /// body lines + title + padding + tail (ja strings) at 10 pt, then scaled with the font.
    /// Never less than the real two-line layout plus slack, so taller designs (serif) still fit.
    var headroom: CGFloat {
        let title = ceil(Self.lineHeight(titleFont)), body = ceil(Self.lineHeight(bodyFont))
        let measured = title + titleSpacing + body * 2 + verticalPadding * 2 + tailBase + Self.stackSpacing
        return max(72 * scale, ceil(measured + 6))
    }
    /// `FloatingPetView` VStack spacing between bubble and sprite.
    static let stackSpacing: CGFloat = 8

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ("Ay" as NSString).boundingRect(with: NSSize(width: 10_000, height: 10_000),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: [.font: font]).height
    }

    var titleFont: NSFont { font(size: titleSize, weight: .bold) }
    var bodyFont: NSFont { font(size: bodySize, weight: .regular) }

    private func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard design != .system, let descriptor = base.fontDescriptor.withDesign(design.appKit) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}
