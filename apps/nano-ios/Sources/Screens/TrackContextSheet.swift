import SwiftUI

/// Track context menu (handoff §03 sheet 1) — local actions only. Source Folder / Remove Download
/// are v2 (cloud) and omitted.
struct TrackContextSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var addToPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        NMArtwork(data: track.artworkData, size: 52, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(Theme.sans(16, .semibold)).foregroundStyle(Theme.text)
                            Text(track.artist).font(Theme.sans(13)).foregroundStyle(Theme.text2)
                            Text("\(track.format) · \(track.sampleRate) kHz").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
                Section {
                    action("Play Next", "text.line.first.and.arrowtriangle.forward") { engine.playNext(track); dismiss() }
                    action("Add to Queue", "list.bullet.indent") { engine.enqueue(track); dismiss() }
                    action("Add to Playlist…", "plus.circle") { addToPlaylist = true }
                    action(track.isLoved ? "Loved" : "Love", track.isLoved ? "heart.fill" : "heart") { track.isLoved.toggle() }
                }.listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addToPlaylist) { AddToPlaylistSheet(track: track) }
        }
        .nmSheetGlass()
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon).foregroundStyle(Theme.text) }
    }
}
