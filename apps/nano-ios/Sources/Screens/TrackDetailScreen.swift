import SwiftUI

/// Interim Phase-3 home for the overview scrubber, reached via a row's ellipsis. The overview View
/// itself is engine-agnostic; this screen wires it to the live AudioEngine. In Phase 4 the overview
/// moves to Now Playing and this screen is retired.
struct TrackDetailScreen: View {
    @Environment(AudioEngine.self) private var engine
    let track: Track
    @State private var bins: [WaveBin] = []

    var body: some View {
        VStack(spacing: 20) {
            NMArtwork(data: track.artworkData, size: 220, radius: 18)
                .padding(.top, 24)
            Text(track.title).font(Theme.sans(22, .bold)).foregroundStyle(Theme.text)
            Text(track.artist).font(Theme.sans(15)).foregroundStyle(Theme.text2)

            OverviewWaveform(
                bins: bins,
                progress: isCurrent ? engine.progress : 0,
                onScrub: { if isCurrent { engine.seek(toFraction: $0) } }
            )
            .padding(.horizontal, Theme.Layout.screenMargin)

            HStack {
                Text(PlaybackMath.clock(isCurrent ? engine.elapsed : 0))
                Spacer()
                Text(lufsString(track.integratedLUFS))
            }
            .font(Theme.mono(12)).foregroundStyle(Theme.text3)
            .padding(.horizontal, Theme.Layout.screenMargin)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .task(id: track.persistentModelID) { bins = await WaveformStore.shared.bins(for: track) ?? [] }
    }

    private var isCurrent: Bool { engine.current?.id == track.id }
    private func lufsString(_ v: Double?) -> String { v.map { String(format: "%.1f LUFS", $0) } ?? "— LUFS" }
}
