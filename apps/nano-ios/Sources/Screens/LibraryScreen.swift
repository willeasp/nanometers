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
        // Header — search + gear only (handoff locks two trailing controls; per-file import lives on All Songs)
        HStack {
            Text("Library")
                .font(Theme.sans(32, .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.text)
            Spacer()
            GlassRoundButton(systemName: "magnifyingglass") { onSearch() }
            GlassRoundButton(systemName: "gearshape") { showSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
        .padding(.bottom, 16)

        // All Songs accent row — two-line SourceRow-style (title + mono subtitle), no trailing count.
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Songs")
                        .font(Theme.sans(16, .medium))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(content.allSongsCount) tracks · everything, flat")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .frame(minHeight: Theme.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if !content.sources.isEmpty {
            // Sources section — no Divider between All Songs row and the header (handoff §3.1)
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
        // (1) Back-link row: ‹ {destination} in Theme.accent
        let backDestination = nav.folderIds.isEmpty
            ? "Library"
            : (content.crumbs.dropLast().last?.label ?? "Library")
        Button(action: { nav.up() }) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(Theme.sans(14, .semibold))
                Text(backDestination)
                    .font(Theme.sans(15))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)

        // (2) Big title
        Text(content.title)
            .font(Theme.sans(28, .bold))
            .tracking(-0.4)
            .foregroundStyle(Theme.text)
            .padding(.bottom, 6)

        // (3) Mono breadcrumb — below the title (handoff §3.2 order)
        if !content.crumbs.isEmpty {
            crumbTrail(crumbs: content.crumbs)
                .padding(.bottom, 10)
        }

        // Play All / Play + Shuffle row
        if content.showsPlayAll {
            let playCtx = folderPlayContext(content: content)
            // Title: "Play" when leaf folder (no sub-folders), "Play All" otherwise (handoff §3.2)
            let playTitle = content.folders.isEmpty ? "Play" : "Play All"
            HStack(spacing: 12) {
                Button {
                    if let first = content.playAll.first {
                        engine.play(first, in: content.playAll, context: playCtx)
                    }
                } label: {
                    Label(playTitle, systemImage: "play.fill")
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

        // Source-root footer: quiet inert label at source root (Phase 4 will wire the deep-link)
        if nav.folderIds.isEmpty {
            Text("Add or manage root folders…")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.bottom, 8)
        }
    }

    // MARK: - All Songs level

    @ViewBuilder
    private func allSongsView(content: BrowseContent) -> some View {
        // Header: back to Library + import button
        // handoff deviation: per-file import lives on All Songs, not the locked root header
        HStack {
            Button(action: { nav.reset() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(Theme.sans(14, .semibold))
                    Text("Library")
                        .font(Theme.sans(15))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            Spacer()
            GlassRoundButton(systemName: "square.and.arrow.down") { importing = true }
        }
        .padding(.bottom, 2)

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

    /// Micro-label section header — uppercase, bold, tight tracking, Theme.text3 (handoff §3.1).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.sans(10.5, .bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Theme.text3)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline mono breadcrumb trail — ancestors `Theme.text3`, separators `Theme.text3`.
    /// All labels `Theme.text2` regular weight (no accent tint on crumbs — handoff §3.2).
    @ViewBuilder
    private func crumbTrail(crumbs: [BrowseContent.Crumb]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                let isLast = idx == crumbs.count - 1
                if idx > 0 {
                    Text(" / ")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text3)
                }
                if isLast {
                    Text(crumb.label)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text2)
                        .accessibilityIdentifier("crumb-\(crumb.label)")
                } else {
                    // Ancestor crumbs dimmed to text3 (not accent-tinted — handoff §3.2)
                    Button(crumb.label) {
                        mapCrumb(crumb.folderDepth)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
                    .accessibilityIdentifier("crumb-\(crumb.label)")
                }
            }
        }
        .lineLimit(1)
        .accessibilityIdentifier("breadcrumb")
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
