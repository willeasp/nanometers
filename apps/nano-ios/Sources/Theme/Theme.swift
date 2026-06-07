import SwiftUI

/// Design tokens, transcribed once from the handoff (`01-design-tokens.md`). Views read these —
/// they never hard-code hexes or sizes. Keep this file the single mirror of §01.
enum Theme {
    // Surfaces
    static let bg      = Color(hex: 0x15171E)
    static let bgElev  = Color(hex: 0x1C1F28)
    static let bgElev2 = Color(hex: 0x232732)
    // Text
    static let text  = Color(hex: 0xF3F4F7)
    static let text2 = Color(hex: 0x9AA1B0)
    static let text3 = Color(hex: 0x626A78)
    // Accent (locked)
    static let accent = Color(hex: 0xEFA869)
    // Frequency bands (handoff §01) — used by the waveforms in Phase 3; defined now for completeness.
    static let bandBass   = Color(hex: 0xFF6B6B)
    static let bandMid    = Color(hex: 0x57D986)
    static let bandTreble = Color(hex: 0x6AA6FF)
    static let bandMix    = Color(hex: 0xEEF1F6)
    // Hairlines / glass
    static let hair        = Color.white.opacity(0.08)
    static let glassBorder = Color.white.opacity(0.10)
    static let glassSheen  = Color.white.opacity(0.14)
    static let artFallback = Color(hex: 0x22252E)

    // Corner radii (§01)
    enum Radius {
        static let albumRow: CGFloat = 7
        static let statTile: CGFloat = 16
        static let tabBar: CGFloat = 30
        static let searchField: CGFloat = 12
        static let mosaic: CGFloat = 12
        static let button: CGFloat = 14
    }

    // Layout (§01)
    enum Layout {
        static let screenMargin: CGFloat = 20
        static let rowMinHeight: CGFloat = 56
        static let rowSeparatorInset: CGFloat = 78   // after 46pt artwork + gaps
        static let scrollBottomPadding: CGFloat = 100 // no-mini case; ~168 once the mini player exists (Phase 2)
    }

    // Fonts — SF Pro for text, SF Mono for ALL numerics (.monospacedDigit), §01.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// 0xRRGGBB literal → Color (sRGB). Used only inside `Theme`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
