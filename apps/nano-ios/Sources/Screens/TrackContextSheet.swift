import SwiftUI

/// Track context menu (handoff §03 sheet 1) — local actions only. Source Folder / Remove Download
/// are v2 (cloud) and omitted.
struct TrackContextSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index
    @Environment(\.modelContext) private var ctx
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

                Section {
                    goToSourceRow
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

    // MARK: - Go to Source

    @ViewBuilder
    private var goToSourceRow: some View {
        let pathLabel = LibraryBrowse.relativePath(for: track, allSongs: true, index: index, ctx: ctx)
        let connected = index.trackPath[track.id] != nil && isConnected

        if connected {
            Button {
                if nav.goToSource(track: track, index: index, ctx: ctx) { dismiss() }
            } label: {
                goToSourceLabel(subtitle: pathLabel.isEmpty ? nil : pathLabel, dimmed: false)
            }
            .accessibilityIdentifier("goToSource")
        } else {
            let sourceLabel = sourceDisplayLabel
            goToSourceLabel(
                subtitle: sourceLabel.map { "\($0) · not connected" },
                dimmed: true
            )
            .accessibilityIdentifier("goToSource")
        }
    }

    private var isConnected: Bool {
        guard let p = index.trackPath[track.id],
              let source = try? LibraryStore.source(id: p.sourceId, ctx) else { return false }
        return SourceState(rawValue: source.state) != .disconnected
    }

    private var sourceDisplayLabel: String? {
        guard let p = index.trackPath[track.id],
              let source = try? LibraryStore.source(id: p.sourceId, ctx) else { return nil }
        return source.label
    }

    private func goToSourceLabel(subtitle: String?, dimmed: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 17))
                .foregroundStyle(dimmed ? Theme.text3 : Theme.text)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Go to Source")
                    .font(Theme.sans(15))
                    .foregroundStyle(dimmed ? Theme.text3 : Theme.text)
                if let sub = subtitle {
                    Text(sub)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .opacity(dimmed ? 0.45 : 1)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon).foregroundStyle(Theme.text) }
    }
}
