import SwiftUI
import SwiftData

struct NewPlaylistSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @State private var name = ""
    @State private var selected = Set<UUID>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
                Text("\(selected.count) selected").font(Theme.mono(12)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                List(tracks) { t in
                    Button { toggle(t.id) } label: {
                        HStack {
                            Image(systemName: selected.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(t.id) ? Theme.accent : Theme.text3)
                            NMArtwork(data: t.artworkData, size: 36, radius: 6)
                            VStack(alignment: .leading) {
                                Text(t.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text)
                                Text(t.artist).font(Theme.sans(12.5)).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .background(Theme.bg)
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(name.isEmpty || selected.isEmpty)
                }
            }
        }
        // NOTE: intentionally no @FocusState autofocus — see handoff §04 lesson (autofocus caused a
        // layout bug in the prototype). The user taps the field.
    }

    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    private func create() {
        // Preserve the library's display order for the chosen ids.
        let ordered = tracks.map(\.id).filter { selected.contains($0) }
        let pl = Playlist(name: name, itemIDs: ordered)
        ctx.insert(pl)
        dismiss()
    }
}
