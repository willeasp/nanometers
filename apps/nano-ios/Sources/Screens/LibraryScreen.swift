import SwiftUI
import SwiftData

struct LibraryScreen: View {
    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index

    // Drive re-renders when SwiftData changes.
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @Query private var sources: [Source]

    @State private var importing = false
    @State private var detailTrack: Track?
    @State private var showSettings = false
    var onSearch: () -> Void = {}

    var body: some View {
        let content = LibraryBrowse.content(for: nav, index: index, ctx: ctx)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch content.level {
                case .root:
                    rootView(content: content)
                case .folder:
                    folderView(content: content)
                case .allSongs:
                    allSongsView(content: content)
                }
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { _ = await TrackImporter.importFiles(urls, into: ctx) }
            }
        }
        .sheet(item: $detailTrack) { TrackContextSheet(track: $0) }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    // MARK: - Root level

    @ViewBuilder
    private func rootView(content: BrowseContent) -> some View {
        // Header
        HStack {
            Text("Library")
                .font(Theme.sans(32, .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.text)
            Spacer()
            GlassRoundButton(systemName: "magnifyingglass") { onSearch() }
            GlassRoundButton(systemName: "folder") { importing = true }
            GlassRoundButton(systemName: "gearshape") { showSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        .padding(.bottom, 16)

        // All Songs accent row
        Button {
            nav.openAllSongs()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                Text("All Songs")
                    .font(Theme.sans(16, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.text)
                if content.allSongsCount > 0 {
                    Spacer(minLength: 8)
                    Text("\(content.allSongsCount)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text3)
                    Image(systemName: "chevron.right")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.text3)
                } else {
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.text3)
                }
            }
            .frame(minHeight: Theme.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if !content.sources.isEmpty {
            Divider().background(Theme.hair)
                .padding(.leading, 78)

            // Sources section
            sectionHeader("Sources")

            LazyVStack(spacing: 0) {
                ForEach(content.sources, id: \.id) { source in
                    SourceRow(
                        source: source,
                        counts: index.sourceCounts[source.id] ?? .init(),
                        onTap: { nav.openSource(source.id) }
                    )
                    if source.id != content.sources.last?.id {
                        Divider().background(Theme.hair)
                            .padding(.leading, 78)
                    }
                }
            }
        }

        // Footer
        Text("Manage sources & root folders in Settings")
            .font(Theme.sans(12))
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Folder level

    @ViewBuilder
    private func folderView(content: BrowseContent) -> some View {
        // Breadcrumb
        LibraryBreadcrumb(
            crumbs: content.crumbs,
            onCrumb: { depth in mapCrumb(depth) },
            onBack: { nav.up() }
        )
        .padding(.bottom, 4)

        // Big title
        Text(content.title)
            .font(Theme.sans(28, .bold))
            .tracking(-0.4)
            .foregroundStyle(Theme.text)
            .padding(.bottom, 12)

        // Play All + Shuffle row
        if content.showsPlayAll {
            let playCtx = folderPlayContext(content: content)
            HStack(spacing: 12) {
                Button {
                    if let first = content.playAll.first {
                        engine.play(first, in: content.playAll, context: playCtx)
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.bgElev2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    engine.playShuffle(content.playAll, context: playCtx)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.bgElev2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)
        }

        if content.folders.isEmpty && content.tracks.isEmpty {
            // Empty state
            Text("This folder is empty.")
                .font(Theme.sans(15))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 48)
        } else {
            // Folders section
            if !content.folders.isEmpty {
                let sectionTitle = nav.folderIds.isEmpty ? "Root Folders" : "Folders"
                sectionHeader(sectionTitle)
                LazyVStack(spacing: 0) {
                    ForEach(content.folders) { node in
                        FolderRow(
                            name: node.name,
                            tint: content.sourceTint,
                            counts: index.folderCounts[node.id] ?? .init(),
                            onTap: { nav.openFolder(node.id) }
                        )
                        if node.id != content.folders.last?.id {
                            Divider().background(Theme.hair)
                                .padding(.leading, 78)
                        }
                    }
                }
            }

            // Tracks section
            if !content.tracks.isEmpty {
                sectionHeader("Tracks")
                let playCtx = folderPlayContext(content: content)
                LazyVStack(spacing: 0) {
                    ForEach(content.tracks) { track in
                        NMRow(
                            track: track,
                            isCurrent: engine.current?.id == track.id,
                            isPlaying: engine.isPlaying && engine.current?.id == track.id,
                            onTap: { engine.play(track, in: content.tracks, context: playCtx) },
                            onEllipsis: { detailTrack = track }
                        )
                        Divider().background(Theme.hair)
                            .padding(.leading, Theme.Layout.rowSeparatorInset)
                    }
                }
            }
        }
    }

    // MARK: - All Songs level

    @ViewBuilder
    private func allSongsView(content: BrowseContent) -> some View {
        // Breadcrumb back to root
        LibraryBreadcrumb(
            crumbs: [],
            onCrumb: { _ in nav.reset() },
            onBack: { nav.reset() }
        )
        .padding(.bottom, 4)

        Text("All Songs")
            .font(Theme.sans(28, .bold))
            .tracking(-0.4)
            .foregroundStyle(Theme.text)
            .padding(.bottom, 12)

        LazyVStack(spacing: 0) {
            ForEach(content.tracks) { track in
                NMRow(
                    track: track,
                    isCurrent: engine.current?.id == track.id,
                    isPlaying: engine.isPlaying && engine.current?.id == track.id,
                    onTap: { engine.play(track, in: content.tracks, context: .library) },
                    onEllipsis: { detailTrack = track }
                )
                Divider().background(Theme.hair)
                    .padding(.leading, Theme.Layout.rowSeparatorInset)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.sans(13, .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Map a breadcrumb `folderDepth` to a LibraryNav mutation.
    /// depth -1 → source root (clear folderIds); depth d → keep first d+1 folders.
    private func mapCrumb(_ depth: Int) {
        if depth < 0 {
            nav.folderIds = []
        } else {
            nav.jumpTo(folderDepth: depth + 1)
        }
    }

    private func folderPlayContext(content: BrowseContent) -> PlayContext {
        // Resolve the source label from the source id in nav, or fall back to the content title.
        let sourceLabel: String
        if let sid = nav.sourceId,
           let src = (try? LibraryStore.source(id: sid, ctx)) {
            sourceLabel = src.label
        } else {
            sourceLabel = content.title
        }
        return PlayContext(kind: "PLAYING FROM \(sourceLabel.uppercased())", name: content.title)
    }
}
