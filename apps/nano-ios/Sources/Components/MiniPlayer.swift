import SwiftUI

/// Docked mini player (handoff §02): artwork · title/artist · play-pause · next, with a 2pt
/// accent progress bar pinned to the bottom edge. Reads the engine from the environment; only
/// renders when a track is loaded. The artwork is the `matchedTransitionSource` for the Now Playing
/// zoom morph; tapping the body opens the cover via `onTapBody`.
/// The optional 56×22 mini-waveform slot (§02) appears once the track's bins are analyzed.
struct MiniPlayer: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var artNamespace: Namespace.ID
    var artSourceID: String
    var onTapBody: () -> Void = {}

    @State private var bins: [WaveBin] = []

    var body: some View {
        if let track = engine.current {
            content(track)
        }
    }

    @ViewBuilder
    private func content(_ track: Track) -> some View {
        HStack(spacing: 0) {
            // Left tap area: artwork + title. A real Button so XCTest can reliably hit-test it.
            Button(action: onTapBody) {
                HStack(spacing: 12) {
                    NMArtwork(data: track.artworkData, size: 44, radius: 9)
                        .matchedTransitionSource(id: artSourceID, in: artNamespace)   // morphs into Now Playing

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            .accessibilityIdentifier("miniPlayerTitle")
                        Text(track.artist)
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miniPlayerBody")

            Spacer(minLength: 8)

            if !bins.isEmpty {
                NMMiniWave(bins: bins, bars: 22, colored: false, tint: Theme.accent)
                    .frame(width: 56, height: 22)
                    .accessibilityHidden(true)
            }

            Button { engine.toggle() } label: {
                ZStack {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18)).foregroundStyle(Theme.text)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))   // replace-look pop, speed we control
                        .id(engine.isPlaying)
                }
                .frame(width: 40, height: 40).contentShape(Rectangle())
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: engine.isPlaying)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("miniPlayerPlayPause")
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
            .sensoryFeedback(.impact(weight: .light), trigger: engine.isPlaying)

            Button { engine.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16)).foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("miniPlayerNext")
            .accessibilityLabel("Next")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .top) {                       // 1px inner-top sheen (matches the glass tab bar)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.glassSheen, lineWidth: 1)
                .blur(radius: 0.5)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
        }
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)   // §01: 0 6 24 @.4 (radius ≈ CSS blur/2)
        .task(id: track.persistentModelID) {
            bins = await WaveformStore.shared.bins(for: track) ?? []
        }
        .padding(.horizontal, 12)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.08))
                Rectangle().fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(engine.progress))
            }
        }
        .frame(height: 2)
    }
}
