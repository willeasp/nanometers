import SwiftUI
import SwiftData

struct PlaylistDetailScreen: View {
    @Environment(\.modelContext) private var ctx
    let playlist: Playlist
    @State private var adding = false

    private var tracks: [Track] { (try? LibraryStore.tracks(in: playlist, ctx)) ?? [] }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    PlaylistCover(artworks: tracks.map(\.artworkData), size: 176)
                    Text(playlist.name).font(Theme.sans(24, .bold)).foregroundStyle(Theme.text)
                    if !playlist.subtitle.isEmpty {
                        Text(playlist.subtitle).font(Theme.sans(14)).foregroundStyle(Theme.text2)
                    }
                    Text("\(tracks.count) songs · \(totalMinutes) min")
                        .font(Theme.mono(13)).foregroundStyle(Theme.text3)
                    HStack(spacing: 12) {
                        actionButton("play.fill", "Play", filled: true)     // Phase 2
                        actionButton("shuffle", "Shuffle", filled: false)   // Phase 2
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(tracks) { NMRow(track: $0) }
                    .onMove { from, to in LibraryStore.move(in: playlist, fromOffsets: from, toOffset: to) }
                    .onDelete { idx in LibraryStore.remove(in: playlist, atOffsets: idx) }
                    .listRowBackground(Theme.bg)

                Button { adding = true } label: {
                    Label("Add Songs…", systemImage: "plus.circle").foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .background(Theme.bg)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { AddSongsSheet(playlist: playlist) }
    }

    private var totalMinutes: Int { Int(tracks.reduce(0) { $0 + $1.durationSec } / 60) }

    private func actionButton(_ icon: String, _ label: String, filled: Bool) -> some View {
        HStack { Image(systemName: icon); Text(label).font(Theme.sans(16.5, .semibold)) }
            .foregroundStyle(filled ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(filled ? Theme.accent : Theme.bgElev2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Minimal add-to-playlist picker (handoff §03 sheet 4 — toggles membership).
private struct AddSongsSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]

    var body: some View {
        NavigationStack {
            List(tracks) { t in
                let inList = playlist.itemIDs.contains(t.id)
                Button {
                    if inList { playlist.itemIDs.removeAll { $0 == t.id } } else { LibraryStore.append(t, to: playlist) }
                } label: {
                    HStack {
                        NMArtwork(data: t.artworkData, size: 36, radius: 6)
                        Text(t.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: inList ? "checkmark" : "plus").foregroundStyle(Theme.accent)
                    }
                }
                .listRowBackground(Theme.bg)
            }
            .listStyle(.plain)
            .background(Theme.bg)
            .navigationTitle("Add Songs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
