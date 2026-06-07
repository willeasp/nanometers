import SwiftUI
import SwiftData

struct PlaylistsScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Playlist.dateCreated, order: .reverse) private var playlists: [Playlist]
    @Query private var tracks: [Track]
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Playlists").font(Theme.sans(32, .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        GlassRoundButton(systemName: "plus") { creating = true }
                    }

                    Button { creating = true } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: Theme.Radius.mosaic, style: .continuous)
                                .strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .frame(width: 60, height: 60)
                                .overlay(Image(systemName: "plus").font(.system(size: 22)).foregroundStyle(Theme.accent))
                            Text("New Playlist").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.accent)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(playlists) { pl in
                        NavigationLink { PlaylistDetailScreen(playlist: pl) } label: { row(pl) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenMargin)
                .padding(.top, 8)   // the ScrollView already clears the status bar via the safe area
                .padding(.bottom, Theme.Layout.scrollBottomPadding)
            }
            .background(Theme.bg)
            .sheet(isPresented: $creating) { NewPlaylistSheet() }
        }
    }

    private func row(_ pl: Playlist) -> some View {
        let arts = (try? LibraryStore.tracks(in: pl, ctx))?.map(\.artworkData) ?? []
        return HStack(spacing: 12) {
            PlaylistCover(artworks: arts, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.name).font(Theme.sans(17, .semibold)).foregroundStyle(Theme.text)
                if !pl.subtitle.isEmpty {
                    Text(pl.subtitle).font(Theme.sans(13.5)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Text("\(pl.itemIDs.count) songs").font(Theme.mono(13)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.text3)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}
