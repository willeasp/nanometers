import SwiftUI

/// The single, persistent player. ONE artwork view morphs between the docked mini slot and the
/// full-screen hero slot, driven by `progress` (0 = mini, 1 = full). Tap-to-expand and the
/// finger-following drag-to-collapse are the SAME continuous mechanism — there is no
/// matchedGeometryEffect and no conditional insert/remove, so exactly one artwork exists in the
/// tree (no ghost / no two-view cross-fade) and the dismiss tracks the finger.
///
/// MiniPlayer and NowPlayingScreen are reused as the *chrome*: each keeps all its content
/// (transport, scrubber, volume, sheets, accessibility ids) but carves its artwork out into a
/// measured `reportPlayerSlot(...)` placeholder; this view draws the one real artwork on top.
struct PlayerContainer: View {
    @Binding var tab: Tab
    @Environment(AudioEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var progress: CGFloat = 0       // THE source of truth: 0 = mini, 1 = full
    @State private var slots: [String: CGRect] = [:]

    private let dismissDistance: CGFloat = 480

    private var miniArt: CGRect { slots["miniArt"] ?? .zero }
    private var heroArt: CGRect { slots["heroArt"] ?? .zero }
    private var artFrame: CGRect { lerpRect(miniArt, heroArt, progress) }
    private var expanded: Bool { progress > 0.5 }
    private var slotsReady: Bool { miniArt != .zero && heroArt != .zero }

    var body: some View {
        ZStack(alignment: .bottom) {
            // (1) FULL chrome — always present, faded by progress, hero artwork carved out.
            NowPlayingScreen(onClose: { setExpanded(false) })
                .opacity(Double(progress))
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
                .ignoresSafeArea()                       // full-bleed; its content insets itself via SafeArea.window
                .gesture(collapseDrag)                   // only fires when expanded (allowsHitTesting)

            // (2) MINI dock + tab bar — fades out as we expand.
            VStack(spacing: 10) {
                if engine.current != nil { MiniPlayer(onTapBody: { setExpanded(true) }) }
                GlassTabBar(selection: $tab)
            }
            .padding(.bottom, SafeArea.window.bottom + 10)
            .opacity(Double(1 - progress))
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)

            // (3) THE single artwork — one element, no second image to ghost.
            if engine.current != nil, slotsReady {
                MorphArtwork(data: engine.current?.artworkData, radius: lerp(9, 18, progress))
                    .frame(width: artFrame.width, height: artFrame.height)
                    .scaleEffect(reduceMotion ? 1 : (engine.isPlaying ? 1 : 0.86 + 0.14 * (1 - progress)))
                    .shadow(color: .black.opacity(0.45 * progress), radius: lerp(0, 30, progress), y: lerp(0, 10, progress))
                    .position(x: artFrame.midX, y: artFrame.midY)
                    .allowsHitTesting(false)             // taps fall through to the chrome beneath
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.isPlaying)
            }
        }
        .coordinateSpace(name: PlayerSpace.name)
        .onPreferenceChange(PlayerSlotKey.self) { slots = $0 }
    }

    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard progress > 0, v.translation.height > 0 else { return }
                progress = 1 - clamp(v.translation.height / dismissDistance, 0, 1)   // pin to the finger — NO animation
            }
            .onEnded { v in
                let flung = v.velocity.height > 800 || v.predictedEndTranslation.height > 300
                setExpanded(!(flung || v.translation.height > 150))
            }
    }

    private func setExpanded(_ on: Bool) {
        withAnimation(.interactiveSpring(response: 0.5, dampingFraction: 0.86, blendDuration: 0.25)) {
            progress = on ? 1 : 0
        }
    }
}
