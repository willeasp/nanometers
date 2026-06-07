import SwiftUI
import SwiftData

/// Toggle a single track's membership across playlists (the inverse of AddSongsSheet). §03 sheet 4.
struct AddToPlaylistSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @Query(sort: \Playlist.dateCreated, order: .reverse) private var playlists: [Playlist]
    @State private var newPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Button { newPlaylist = true } label: {                 // §4 first row: New Playlist (dashed tile)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .overlay(Image(systemName: "plus").foregroundStyle(Theme.accent))
                            .frame(width: 44, height: 44)
                        Text("New Playlist").font(Theme.sans(16.5, .semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                }.listRowBackground(Theme.bg)

                ForEach(playlists) { pl in
                    let inList = pl.itemIDs.contains(track.id)
                    Button {
                        if inList { pl.itemIDs.removeAll { $0 == track.id } } else { LibraryStore.append(track, to: pl) }
                    } label: {
                        HStack {
                            PlaylistCover(artworks: (try? LibraryStore.tracks(in: pl, ctx))?.map(\.artworkData) ?? [], size: 44)
                            Text(pl.name).font(Theme.sans(16, .medium)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: inList ? "checkmark" : "plus").foregroundStyle(Theme.accent)
                        }
                    }.listRowBackground(Theme.bg)
                }
            }
            .listStyle(.plain).background(Theme.bg)
            .navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $newPlaylist) { NewPlaylistSheet() }
        }
        .preferredColorScheme(.dark)
    }
}
