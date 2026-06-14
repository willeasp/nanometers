import SwiftUI

/// Full-screen Now Playing surface, presented as a `.fullScreenCover` with the native zoom transition
/// (see RootView). The hero artwork is a plain `NMArtwork`; the zoom transition morphs the whole
/// surface to/from the mini-player artwork and provides the interactive swipe-to-dismiss, so there is
/// no morph code here.
///
/// The zoom-presented cover hands its content a *bogus* safe area (top reads ≈0, so a `GeometryReader`
/// read here puts the chrome behind the Dynamic Island). So we don't read our own insets — `RootView`
/// reads the real device insets where the hierarchy reports them correctly and threads them in via
/// `safeArea`. The gradient bleeds full (`.ignoresSafeArea`); the chrome pads by `safeArea`.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index
    @Environment(\.modelContext) private var ctx
    var onClose: () -> Void
    /// True device safe-area insets, read by `RootView` (the cover's own insets are wrong — see above).
    var safeArea: EdgeInsets = EdgeInsets()

    @State private var tint: Color = Theme.bgElev2
    @State private var showContext = false
    @State private var showQueue = false

    @AppStorage("showWave") private var showWave = true
    @AppStorage("spectrum") private var spectrum = false
    @AppStorage("zoomWave") private var zoomWave = false        // close-up (DJ scroll); off in v1
    @State private var bins: [WaveBin] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion   // gates the motion flourishes (§01)

    var body: some View {
        // Full-bleed gradient; chrome positioned by the real device insets threaded in from RootView
        // (the cover's own insets are wrong — see the type doc). +8 on top gives the island some air.
        VStack(spacing: 14) {
            topBar
            hero                                         // takes the leftover space, capped + shrinks to fit
            titleRow
            closeUp          // §05/§03D: close-up sits above the full-song scrubber
            scrubber
            timeRow
            transportRow
            volumeRow
            bottomRail
        }
        .padding(.horizontal, 26)
        .padding(.top, safeArea.top + 8)
        .padding(.bottom, safeArea.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(npGradient.ignoresSafeArea())
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { tint = await ArtworkTintStore.shared.tint(for: t) }
        }
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { bins = await WaveformStore.shared.bins(for: t) ?? [] }
        }
        .sheet(isPresented: $showContext) {
            if let t = engine.current { TrackContextSheet(track: t) }
        }
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    @ViewBuilder private var closeUp: some View {
        if zoomWave, !bins.isEmpty, let dur = engine.current?.durationSec, dur > 0 {
            CloseUpWaveform(bins: bins,
                            currentTime: { engine.centerTime },
                            duration: dur,
                            coloringOn: spectrum,
                            isPlaying: engine.isPlaying,
                            redrawTrigger: engine.elapsed)   // observed → re-centers on scrub-while-paused
        }
    }

    @ViewBuilder private var scrubber: some View {
        if showWave {
            OverviewWaveform(bins: bins, progress: engine.progress, coloringOn: spectrum,
                             onScrub: { engine.seek(toFraction: $0) }, height: 46)
                .overlay(alignment: .topTrailing) {
                    LUFSBadge(lufs: engine.momentaryLUFS).offset(y: -6)
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
            }.buttonStyle(PressableButtonStyle()).frame(maxWidth: .infinity)
            .sensoryFeedback(.selection, trigger: engine.isShuffle)

            Button { engine.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(PressableButtonStyle()).frame(maxWidth: .infinity)

            Button { engine.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30)).foregroundStyle(Theme.bg)   // dark-on-amber (§03D)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))   // replace-look pop, at a speed we control
                        .id(engine.isPlaying)                                       // (native symbolEffect.replace's duration is fixed/slower)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: engine.isPlaying)   // matches the artwork scale
            }.buttonStyle(PressableButtonStyle()).frame(maxWidth: .infinity)
            .accessibilityIdentifier("npPlayPause").accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .light), trigger: engine.isPlaying)

            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(PressableButtonStyle()).frame(maxWidth: .infinity)

            Button { engine.setRepeat(!engine.isRepeat) } label: {
                Image(systemName: "repeat").font(.system(size: 22))
                    .foregroundStyle(engine.isRepeat ? Theme.accent : .white.opacity(0.85))
            }.buttonStyle(PressableButtonStyle()).frame(maxWidth: .infinity)
            .sensoryFeedback(.selection, trigger: engine.isRepeat)
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

    /// Full-bleed backdrop: artwork tint → mid → bottom, with the §03D faint glass scrim.
    private var npGradient: some View {
        LinearGradient(stops: [.init(color: tint, location: 0),
                               .init(color: Theme.npGradientMid, location: 0.46),
                               .init(color: Theme.npGradientBottom, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {                                       // §03D faint glass scrim (system material per §01)
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.18)
                    Theme.npGradientBottom.opacity(0.35)     // #111319 @ 0.35
                }.allowsHitTesting(false)
            }
    }

    /// Resizable hero: a square that fills the leftover vertical space, capped at the §03D 340pt limit
    /// and shrinking on shorter screens so the transport + rail always fit. (`NMArtwork` is fixed-size.)
    @ViewBuilder private var hero: some View {
        let radius: CGFloat = 18
        Group {
            if let data = engine.current?.artworkData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Theme.artFallback.overlay {
                    GeometryReader { g in
                        Image(systemName: "waveform")
                            .font(.system(size: g.size.width * 0.42))
                            .foregroundStyle(.white.opacity(0.22))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340, maxHeight: 340)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .scaleEffect(reduceMotion ? 1 : (engine.isPlaying ? 1 : 0.86))   // §motion: paused artwork shrinks to 0.86
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: engine.isPlaying)
        .frame(maxHeight: .infinity)                  // claim the leftover space; the art centers + caps within it
        .shadow(color: .black.opacity(0.45), radius: 15, y: 10)   // §01: 0 10 30 @.45 (radius ≈ CSS blur/2)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)      // + the tight contact shadow (0 2 8 @.3)
    }

    @ViewBuilder private var bottomRail: some View {
        HStack {
            // Go to Source: enabled when current track has a resolvable connected path
            let canGoToSource = engine.current.map { t in
                guard let p = index.trackPath[t.id],
                      let source = try? LibraryStore.source(id: p.sourceId, ctx) else { return false }
                return SourceState(rawValue: source.state) != .disconnected
            } ?? false

            Button {
                if let t = engine.current, nav.goToSource(track: t, index: index, ctx: ctx) {
                    onClose()
                }
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 20))
                    .foregroundStyle(canGoToSource ? Theme.text2 : Theme.text3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!canGoToSource)
            .opacity(canGoToSource ? 1 : 0.4)
            .accessibilityIdentifier("npGoToSource")

            AirPlayButton().frame(width: 44, height: 44).frame(maxWidth: .infinity)
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet.indent").font(.system(size: 20)).foregroundStyle(Theme.text2)
            }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier("npQueue")
        }
    }
}
