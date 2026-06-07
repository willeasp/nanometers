import SwiftUI
import UIKit

/// The shared coordinate space the mini + hero artwork slots are measured in, so the single floating
/// artwork can lerp between them.
enum PlayerSpace { static let name = "player" }

/// Reports the frames of the named artwork "slots" (mini / hero) up to `PlayerContainer`.
struct PlayerSlotKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reserve an empty, measured slot the floating artwork lerps into. Both slots are read in the
    /// shared `PlayerSpace` so their frames line up regardless of safe-area handling.
    func reportPlayerSlot(_ id: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: PlayerSlotKey.self,
                                       value: [id: geo.frame(in: .named(PlayerSpace.name))])
            }
        )
    }
}

@inline(__always) func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(x, lo), hi) }
@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

/// The REAL device safe-area insets (key window). Used where SwiftUI's own insets are zeroed by a
/// full-bleed ancestor (the player overlay).
enum SafeArea {
    @MainActor static var window: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
    }
}
