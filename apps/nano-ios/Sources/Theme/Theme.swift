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
    static let glassBorder = Color.white.opacity(0.12)   // §01 materials edge treatment (the prototype uses 12% on every glass surface)
    static let glassSheen  = Color.white.opacity(0.14)
    static let artFallback = Color(hex: 0x22252E)
    // Now Playing gradient stops (§01 / §03D background).
    static let npGradientMid    = Color(hex: 0x14161C)
    static let npGradientBottom = Color(hex: 0x111319)

    // Now Playing redesign (§06F): neutral warm gradient (168°) — no per-track album-art tint.
    static let npBgTop    = Color(hex: 0x232029)
    static let npBgMid    = Color(hex: 0x1A1820)
    static let npBgBottom = Color(hex: 0x131218)
    // Flip-card back face gradient (158°, §06B).
    static let cardBackTop    = Color(hex: 0x221F2A)
    static let cardBackMid    = Color(hex: 0x18171F)
    static let cardBackBottom = Color(hex: 0x131218)

    // Corner radii (§01)
    enum Radius {
        static let albumRow: CGFloat = 7
        static let statTile: CGFloat = 16
        static let tabBar: CGFloat = 30
        static let searchField: CGFloat = 12
        static let mosaic: CGFloat = 12
        static let button: CGFloat = 14
        static let albumNowPlaying: CGFloat = 18   // §03D artwork hero
        static let flipCard: CGFloat = 22          // §06B flip card
    }

    // Layout (§01)
    enum Layout {
        static let screenMargin: CGFloat = 20
        static let rowMinHeight: CGFloat = 56
        static let rowSeparatorInset: CGFloat = 78   // after 46pt artwork + gaps
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

    /// "#RRGGBB" (or "RRGGBB") → Color; `.clear` on malformed input. Used by the artwork-tint cache.
    init(hex string: String) {
        let s = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .clear; return }
        self.init(hex: v)
    }
}
