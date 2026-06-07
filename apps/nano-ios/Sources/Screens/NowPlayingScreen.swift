import SwiftUI

/// Full-screen Now Playing surface, presented as an in-tree overlay from RootView (NOT a cover —
/// matchedGeometryEffect can't cross a cover/sheet boundary). Sections are built up across Phase 4
/// tasks. The hero artwork morphs from the mini player's 44pt tile via the shared namespace.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    var namespace: Namespace.ID
    var onClose: () -> Void

    @State private var tint: Color = Theme.bgElev2
    @State private var showContext = false

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: tint, location: 0),
                                   .init(color: Theme.npGradientMid, location: 0.46),
                                   .init(color: Theme.npGradientBottom, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .overlay {                                   // §03D faint glass scrim (system material per §01)
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).opacity(0.18)
                        Theme.npGradientBottom.opacity(0.35)     // #111319 @ 0.35
                    }.allowsHitTesting(false)
                }
                .ignoresSafeArea()

            VStack(spacing: 18) {
                topBar
                Spacer(minLength: 8)
                hero
                Spacer(minLength: 8)
                titleRow
                transportRow
            }
            .padding(.horizontal, 26)
            .padding(.top, 8).padding(.bottom, 28)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { tint = await ArtworkTintStore.shared.tint(for: t) }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { onClose() } })
        .sheet(isPresented: $showContext) {
            if let t = engine.current { TrackContextSheet(track: t) }
        }
    }

    @ViewBuilder private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(engine.context.kind)
                    .font(Theme.sans(10.5, .bold)).tracking(1.4).foregroundStyle(.white.opacity(0.5))
                Text(engine.context.name)
                    .font(Theme.sans(13, .semibold)).foregroundStyle(Theme.text)
            }
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }.accessibilityIdentifier("npDismiss")
                Spacer()
                Button { showContext = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 24))
                        .foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }.accessibilityIdentifier("npEllipsis")
            }
        }
    }

    @ViewBuilder private var titleRow: some View {
        if let track = engine.current {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(Theme.sans(22, .bold)).tracking(-0.3).foregroundStyle(Theme.text).lineLimit(1)
                    Text(track.artist).font(Theme.sans(17)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { track.isLoved.toggle() } label: {
                    Image(systemName: track.isLoved ? "heart.fill" : "heart")
                        .font(.system(size: 24)).foregroundStyle(track.isLoved ? Theme.accent : Theme.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityIdentifier("npHeart")
            }
        }
    }

    @ViewBuilder private var transportRow: some View {
        HStack {
            Button { engine.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 22))
                    .foregroundStyle(engine.isShuffle ? Theme.accent : .white.opacity(0.85))
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36)).foregroundStyle(Theme.bg)   // dark-on-amber (§03D)
                }
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
            .accessibilityIdentifier("npPlayPause").accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.setRepeat(!engine.isRepeat) } label: {
                Image(systemName: "repeat").font(.system(size: 22))
                    .foregroundStyle(engine.isRepeat ? Theme.accent : .white.opacity(0.85))
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
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

// TEMP stub — replaced by the real TrackContextSheet in Phase 4 Task 9.
struct TrackContextSheet: View { let track: Track; var body: some View { Text(track.title).padding() } }
