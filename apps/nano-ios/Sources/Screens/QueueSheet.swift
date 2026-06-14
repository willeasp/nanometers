import SwiftUI

/// Up Next — the live queue (handoff §03 sheet 7): now-playing header + the upcoming list + an
/// "End of queue" empty state; title carries the current context name. Tapping a row jumps to it.
struct QueueSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var bins: [WaveBin] = []
    @State private var contextTrack: Track?

    /// (absolute queue index, track) for everything AFTER the current index.
    private var upcoming: [(offset: Int, track: Track)] {
        let tracks = engine.queue.tracks, idx = engine.queue.index
        guard idx + 1 < tracks.count else { return [] }
        return tracks[(idx + 1)...].enumerated().map { (idx + 1 + $0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let cur = engine.current {                       // now-playing header block
                    HStack(spacing: 12) {
                        NMArtwork(data: cur.artworkData, size: 44, radius: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cur.title).font(Theme.sans(15.5, .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                            Text("Now Playing").font(Theme.sans(12.5)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        if !bins.isEmpty { NMMiniWave(bins: bins, bars: 22).frame(width: 48, height: 20) }
                    }
                    .listRowBackground(Color.clear)
                    Divider().background(Theme.hair).listRowBackground(Color.clear)
                }
                if upcoming.isEmpty {
                    Text("End of queue").font(Theme.sans(14)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
                } else {
                    ForEach(upcoming, id: \.offset) { item in   // positional id: a track may legitimately appear twice in the queue
                        HStack(spacing: 12) {
                            NMArtwork(data: item.track.artworkData, size: 42, radius: 8)
                            VStack(alignment: .leading) {
                                Text(item.track.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(item.track.artist).font(Theme.sans(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                            }
                            Spacer()
                            Button { contextTrack = item.track } label: {
                                Image(systemName: "ellipsis")
                                    .font(Theme.sans(16))
                                    .foregroundStyle(Theme.text3)
                                    .frame(width: 34, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("rowEllipsis")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { engine.jump(to: item.offset); dismiss() }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Up Next").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.text)
                        Text(engine.context.name).font(Theme.mono(12)).foregroundStyle(Theme.text3)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: engine.current?.persistentModelID) {
                if let c = engine.current { bins = await WaveformStore.shared.bins(for: c) ?? [] }
            }
            .sheet(item: $contextTrack) { TrackContextSheet(track: $0) }
        }
        .nmSheetGlass()
        .preferredColorScheme(.dark)
    }
}
