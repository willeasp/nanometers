import SwiftUI

/// Full-screen Now Playing surface, presented as an in-tree overlay from RootView (NOT a cover —
/// matchedGeometryEffect can't cross a cover/sheet boundary). Sections are built up across Phase 4
/// tasks. The hero artwork morphs from the mini player's 44pt tile via the shared namespace.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    var namespace: Namespace.ID
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Theme.npGradientBottom.ignoresSafeArea()   // Task 3 swaps this for the tint gradient

            VStack(spacing: 18) {
                topBar
                Spacer(minLength: 8)
                hero
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 26)
            .padding(.top, 8).padding(.bottom, 28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
        .contentShape(Rectangle())
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { onClose() } })
    }

    @ViewBuilder private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.text).frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("npDismiss")
            Spacer()
        }
    }

    @ViewBuilder private var hero: some View {
        if let track = engine.current {
            NMArtwork(data: track.artworkData, size: 340, radius: Theme.Radius.albumNowPlaying)   // §03D ≤340 cap
                .matchedGeometryEffect(id: "artwork-\(track.id)", in: namespace)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .scaleEffect(engine.isPlaying ? 1.0 : 0.86)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: engine.isPlaying)
        }
    }
}
