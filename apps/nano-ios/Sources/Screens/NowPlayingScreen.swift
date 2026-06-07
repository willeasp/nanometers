import SwiftUI

/// Full-screen Now Playing surface, presented as an in-tree overlay from RootView (NOT a cover —
/// matchedGeometryEffect can't cross a cover/sheet boundary). Sections are built up across Phase 4
/// tasks. The hero artwork morphs from the mini player's 44pt tile via the shared namespace.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var namespace: Namespace.ID
    var onClose: () -> Void

    @State private var tint: Color = Theme.bgElev2
    @State private var showContext = false
    @State private var showQueue = false

    @AppStorage("showWave") private var showWave = true
    @AppStorage("spectrum") private var spectrum = false
    @State private var bins: [WaveBin] = []

    var body: some View {
        VStack(spacing: 18) {
            topBar
            Spacer(minLength: 8)
            hero
            Spacer(minLength: 8)
            titleRow
            scrubber
            timeRow
            transportRow
            volumeRow
            bottomRail
        }
        .padding(.horizontal, 26)
        .padding(.top, 8).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the screen; content stays within the safe area
        .background {                                        // gradient bleeds full-screen, the content above does NOT
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { tint = await ArtworkTintStore.shared.tint(for: t) }
        }
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { bins = await WaveformStore.shared.bins(for: t) ?? [] }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { onClose() } })
        .sheet(isPresented: $showContext) {
            if let t = engine.current { TrackContextSheet(track: t) }
        }
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    @ViewBuilder private var scrubber: some View {
        if showWave {
            OverviewWaveform(bins: bins, progress: engine.progress, coloringOn: spectrum,
                             onScrub: { engine.seek(toFraction: $0) })
                .overlay(alignment: .topTrailing) {
                    LUFSBadge(lufs: engine.current?.integratedLUFS).offset(y: -6)
                }
        } else {                                   // both/overview off → plain 6pt bar (§03D item 5)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16)).frame(height: 6)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(engine.progress), height: 6)
                    Circle().fill(.white).frame(width: 14, height: 14)              // §03D item 5: 14pt white knob
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .offset(x: max(0, min(geo.size.width - 14, geo.size.width * CGFloat(engine.progress) - 7)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { engine.seek(toFraction: min(1, max(0, $0.location.x / geo.size.width))) })
            }
            .frame(height: 14)
        }
    }

    @ViewBuilder private var timeRow: some View {
        let dur = engine.current?.durationSec ?? 0
        HStack {
            Text(PlaybackMath.clock(engine.elapsed))
            Spacer()
            if !showWave {                                   // no overview → LUFS sits inline here as plain text (NOT the capsule)
                Text((engine.current?.integratedLUFS).map { String(format: "%.1f LUFS", $0) } ?? "— LUFS")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            Text("-" + PlaybackMath.clock(max(0, dur - engine.elapsed)))
        }
        .font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
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
                        .accessibilityIdentifier("npTitle")
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

    @ViewBuilder private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(.white.opacity(0.4))
            GeometryReader { geo in                                    // custom: track white@14%, fill white@85%, white knob
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.85)).frame(width: w * CGFloat(engine.volume), height: 4)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .offset(x: max(0, min(w - 14, w * CGFloat(engine.volume) - 7)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { engine.setVolume(min(1, max(0, $0.location.x / w))) })
            }
            .frame(height: 24).accessibilityIdentifier("npVolume")
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))  // asymmetric 16/22 (§ JSX)
        }
    }

    @ViewBuilder private var hero: some View {
        if let track = engine.current {
            NMArtwork(data: track.artworkData, size: 340, radius: Theme.Radius.albumNowPlaying)   // §03D ≤340 cap
                .matchedGeometryEffect(id: "nowPlayingArtwork", in: namespace)   // constant id: persists across track changes (no ghost)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .scaleEffect(reduceMotion ? 1.0 : (engine.isPlaying ? 1.0 : 0.86))
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: engine.isPlaying)
        }
    }

    @ViewBuilder private var bottomRail: some View {
        HStack {
            Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity).opacity(0.4)        // Go-to-Source-Folder is v2
            AirPlayButton().frame(width: 44, height: 44).frame(maxWidth: .infinity)
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet.indent").font(.system(size: 20)).foregroundStyle(Theme.text2)
            }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier("npQueue")
        }
    }
}
