import SwiftUI
import SwiftData

struct LibraryScreen: View {
    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @Query private var playlists: [Playlist]
    @State private var importing = false
    @State private var detailTrack: Track?
    var onSearch: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Library").font(Theme.sans(32, .bold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    GlassRoundButton(systemName: "magnifyingglass") { onSearch() }
                    GlassRoundButton(systemName: "folder") { importing = true }   // shell: import; Sources hub is v2
                    GlassRoundButton(systemName: "gearshape")                       // Settings sheet is Phase 4
                }

                HStack(spacing: 10) {
                    StatTile(icon: "music.note", title: "All Songs", detail: "\(tracks.count) tracks")
                    StatTile(icon: "rectangle.stack", title: "Playlists", detail: "\(playlists.count)")
                }

                HStack {
                    Text("Songs").font(Theme.sans(20, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(tracks.count)").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.text3)
                }
                .padding(.top, 4)

                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        NMRow(
                            track: track,
                            isCurrent: engine.current?.id == track.id,
                            isPlaying: engine.isPlaying && engine.current?.id == track.id,
                            onTap: { engine.play(track, in: tracks, context: .library) },
                            onEllipsis: { detailTrack = track }
                        )
                        Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 50)
            .padding(.bottom, engine.current == nil ? Theme.Layout.scrollBottomPadding : Theme.Layout.scrollBottomPaddingPlaying)
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { _ = await TrackImporter.importFiles(urls, into: ctx) }
            }
        }
        .sheet(item: $detailTrack) { TrackContextSheet(track: $0) }
    }
}

private struct StatTile: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.text2)
            Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(Theme.mono(12.5)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 14)
        .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.statTile, style: .continuous))
    }
}
