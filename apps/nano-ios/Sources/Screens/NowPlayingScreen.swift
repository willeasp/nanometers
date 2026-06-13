import SwiftUI

/// Full-screen Now Playing surface (handoff §06), presented as a `.fullScreenCover` with the native
/// zoom transition (see RootView). The hero is a `FlipHero`: its front is the album artwork and it
/// flips to the analysis B-side (close-up scope · goniometer · spectrum). The cover⇄mini zoom morph
/// (RootView) provides the interactive swipe-to-dismiss and the artwork morph — there's no morph code
/// here, and the flip lives *inside* the cover.
///
/// The zoom-presented cover hands its content a *bogus* safe area (top reads ≈0, so a `GeometryReader`
/// read here puts the chrome behind the Dynamic Island). So we don't read our own insets — `RootView`
/// reads the real device insets where the hierarchy reports them correctly and threads them in via
/// `safeArea`. The gradient bleeds full (`.ignoresSafeArea`); the chrome pads by `safeArea`.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    var onClose: () -> Void
    /// True device safe-area insets, read by `RootView` (the cover's own insets are wrong — see above).
    var safeArea: EdgeInsets = EdgeInsets()

    @State private var showContext = false
    @State private var showQueue = false
    @State private var showSettings = false
    @State private var flipped = false

    @AppStorage("showWave") private var showWave = true
    @AppStorage("spectrum") private var spectrum = true     // frequency coloring (close-up); default on (§06E)
    @AppStorage("scopeWindow") private var scopeWindow = 4  // close-up window seconds (3/4/5; §06E)
    @AppStorage("modules") private var modulesCSV = "scope" // selected meters (CSV, min 1; §06E)
    @State private var bins: [WaveBin] = []
    @State private var closeUpBins: [StereoWaveBin] = []

    var body: some View {
        VStack(spacing: 14) {
            topBar
            FlipHero(artworkData: engine.current?.artworkData, flipped: $flipped) {
                AnalysisArea(modulesCSV: $modulesCSV,
                             closeUpBins: closeUpBins,
                             currentTime: { engine.centerTime },
                             duration: engine.current?.durationSec ?? 0,
                             coloringOn: spectrum,
                             windowSec: Double(scopeWindow),
                             redrawTrigger: engine.elapsed,
                             onScrub: { engine.seek(toFraction: $0) },
                             liveSamples: { engine.liveScope($0) },
                             scopeWritten: { engine.scopeWritten },
                             scopeRate: { engine.scopeRate },
                             scopeWindow: { engine.scopeWindow(endingAt: $0, count: $1) },
                             isPlaying: engine.isPlaying,
                             active: flipped,
                             lufs: engine.momentaryLUFS)
            }
            titleRow
            scrubber
            timeRow
            transportRow
            volumeRow
            bottomRail
        }
        .padding(.horizontal, 22)
        .padding(.top, safeArea.top + 8)
        .padding(.bottom, safeArea.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(npGradient.ignoresSafeArea())
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
        .task(id: engine.current?.persistentModelID) {
            guard let t = engine.current else { return }
            bins = await WaveformStore.shared.bins(for: t) ?? []
            closeUpBins = await WaveformStore.shared.closeUpBins(for: t) ?? []
        }
        .onChange(of: engine.current?.persistentModelID) { flipped = false }   // §06B reset to cover on track change
        .sheet(isPresented: $showContext) {
            if let t = engine.current { TrackContextSheet(track: t) }
        }
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        #if DEBUG
        .onAppear {   // headless screenshot hooks (no tap): -flipAnalysis shows the B-side, -openSettings the sheet
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-flipAnalysis") {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); flipped = true }
            }
            if args.contains("-openSettings") {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.4)); showSettings = true }
            }
        }
        #endif
    }

    @ViewBuilder private var scrubber: some View {
        if showWave {
            OverviewWaveform(bins: bins, progress: engine.progress, coloringOn: spectrum,
                             onScrub: { engine.seek(toFraction: $0) }, height: 30)   // §06: slim 30pt, no LUFS here
        } else {                                   // overview off → plain slim bar with a white knob (§06)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16)).frame(height: 5)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(engine.progress), height: 5)
                    Circle().fill(.white).frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .offset(x: max(0, min(geo.size.width - 13, geo.size.width * CGFloat(engine.progress) - 6.5)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { engine.seek(toFraction: min(1, max(0, $0.location.x / geo.size.width))) })
            }
            .frame(height: 14)
            .accessibilityIdentifier("overviewWaveform")
        }
    }

    @ViewBuilder private var timeRow: some View {
        let dur = engine.current?.durationSec ?? 0
        HStack {
            Text(PlaybackMath.clock(engine.elapsed))
            Spacer()
            Text("-" + PlaybackMath.clock(max(0, dur - engine.elapsed)))
        }
        .font(Theme.mono(11.5)).foregroundStyle(.white.opacity(0.46))   // §06 elapsed left / -remaining right only
    }

    @ViewBuilder private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(engine.context.kind)
                    .font(Theme.mono(10, .bold)).tracking(1.6).foregroundStyle(.white.opacity(0.42))
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(Theme.sans(21, .bold)).tracking(-0.3).foregroundStyle(Theme.text).lineLimit(1)
                        .accessibilityIdentifier("npTitle")
                    HStack(spacing: 8) {
                        Text(track.artist).font(Theme.sans(15)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                        Text(formatLine(track))
                            .font(Theme.mono(10.5)).tracking(0.4).foregroundStyle(Theme.text3).lineLimit(1).layoutPriority(1)
                    }
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

    /// §06 title format line: "FLAC · 24/96" when a PCM bit depth is known, else "FLAC · 96 kHz"
    /// (lossy), else just the format. Numerics are mono.
    private func formatLine(_ t: Track) -> String {
        guard !t.format.isEmpty else { return "" }
        if let bits = t.bitDepth, !t.sampleRate.isEmpty { return "\(t.format) · \(bits)/\(t.sampleRate)" }
        if !t.sampleRate.isEmpty { return "\(t.format) · \(t.sampleRate) kHz" }
        return t.format
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
                    Circle().fill(Theme.accent).frame(width: 70, height: 70)             // §06 70pt amber
                        .shadow(color: Theme.accent.opacity(0.4), radius: 13, y: 6)      // §06 accent glow
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30)).foregroundStyle(Theme.bg)               // dark-on-amber (§01)
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
            GeometryReader { geo in                                    // track white@14%, fill white@85%, white knob
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
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
        }
    }

    /// §06F neutral warm gradient (168°) + a soft accent aura at the top. No per-track album-art tint.
    private var npGradient: some View {
        LinearGradient(stops: [.init(color: Theme.npBgTop, location: 0),
                               .init(color: Theme.npBgMid, location: 0.44),
                               .init(color: Theme.npBgBottom, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                RadialGradient(colors: [Theme.accent.opacity(0.16), .clear],
                               center: .top, startRadius: 0, endRadius: 360)
                    .frame(height: 300)
                    .allowsHitTesting(false)
            }
    }

    /// §06 bottom rail: source folder (v2 placeholder) · Settings · AirPlay · queue. AirPlay kept per
    /// the user override of the handoff's 3-icon rail.
    @ViewBuilder private var bottomRail: some View {
        HStack {
            Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity).opacity(0.4)        // Go-to-Source-Folder is v2
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 22)).foregroundStyle(.white.opacity(0.78))
            }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier("npSettings")
            AirPlayButton().frame(width: 44, height: 44).frame(maxWidth: .infinity)
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet.indent").font(.system(size: 24)).foregroundStyle(.white.opacity(0.78))
            }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier("npQueue")
        }
    }
}
