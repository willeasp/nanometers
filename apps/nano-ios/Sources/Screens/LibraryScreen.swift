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
    @State private var searchActive = false
    @State private var searchQuery = ""
    var onSearch: () -> Void = {}

    // Derived key from nav state — any change auto-clears the search.
    private var navKey: String {
        "\(nav.smart == nil ? "nil" : "smart")-\(nav.sourceId ?? "")-\(nav.folderIds.joined())"
    }

    var body: some View {
        let content = LibraryBrowse.content(for: nav, index: index, ctx: ctx)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch content.level {
                    case .root:
                        rootView(content: content)
                    case .folder:
                        folderView(content: content, proxy: proxy)
                    case .allSongs:
                        allSongsView(content: content, proxy: proxy)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenMargin)
                .padding(.top, 8)
            }
            .onChange(of: navKey) {
                searchActive = false
                searchQuery = ""
            }
            // Task 4: scroll to highlighted track and clear after ~2.8 s
            .task(id: nav.highlightTrackId) {
                guard let tid = nav.highlightTrackId else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(tid, anchor: .center)
                }
                try? await Task.sleep(for: .seconds(2.8))
                nav.highlightTrackId = nil
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
    private func folderView(content: BrowseContent, proxy: ScrollViewProxy) -> some View {
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

        // (2) Big title + search toggle
        HStack(alignment: .center, spacing: 10) {
            Text(content.title)
                .font(Theme.sans(28, .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if !content.playAll.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchActive.toggle()
                        if !searchActive { searchQuery = "" }
                    }
                } label: {
                    Image(systemName: searchActive ? "xmark" : "magnifyingglass")
                        .font(Theme.sans(17, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("searchToggle")
            }
        }
        .padding(.bottom, searchActive ? 8 : 6)

        // (3) Scoped search field (shown when searchActive)
        if searchActive {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("Search in \(content.title)", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("scopedSearchField")
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
            .padding(.bottom, 6)
        }

        // (3b) Mono breadcrumb — below the title (handoff §3.2 order)
        if !content.crumbs.isEmpty {
            crumbTrail(crumbs: content.crumbs)
                .padding(.bottom, 10)
        }

        // Search results or normal content
        if searchActive && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResultsView(content: content, proxy: proxy)
        } else {
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
                            .id(track.id)
                            .background(highlightBackground(for: track))
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
    }

    // MARK: - All Songs level

    @ViewBuilder
    private func allSongsView(content: BrowseContent, proxy: ScrollViewProxy) -> some View {
        // Header: back to Library + search toggle + import button
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
            if !content.playAll.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchActive.toggle()
                        if !searchActive { searchQuery = "" }
                    }
                } label: {
                    Image(systemName: searchActive ? "xmark" : "magnifyingglass")
                        .font(Theme.sans(17, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("searchToggle")
            }
            GlassRoundButton(systemName: "square.and.arrow.down") { importing = true }
        }
        .padding(.bottom, 2)

        Text("All Songs")
            .font(Theme.sans(28, .bold))
            .tracking(-0.4)
            .foregroundStyle(Theme.text)
            .padding(.bottom, searchActive ? 8 : 12)

        // Scoped search field (shown when searchActive)
        if searchActive {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("Search in \(content.title)", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("scopedSearchField")
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
            .padding(.bottom, 8)
        }

        if searchActive && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResultsView(content: content, proxy: proxy)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(content.tracks) { track in
                    NMRow(
                        track: track,
                        isCurrent: engine.current?.id == track.id,
                        isPlaying: engine.isPlaying && engine.current?.id == track.id,
                        onTap: { engine.play(track, in: content.tracks, context: .library) },
                        onEllipsis: { detailTrack = track }
                    )
                    .id(track.id)
                    .background(highlightBackground(for: track))
                    Divider().background(Theme.hair)
                        .padding(.leading, Theme.Layout.rowSeparatorInset)
                }
            }
        }
    }

    // MARK: - Scoped search results

    @ViewBuilder
    private func searchResultsView(content: BrowseContent, proxy: ScrollViewProxy) -> some View {
        let hits = LibraryBrowse.search(content.playAll, query: searchQuery, nav: nav, index: index, ctx: ctx)
        let q = searchQuery.trimmingCharacters(in: .whitespaces)

        // Helper line
        if hits.isEmpty {
            Text("No tracks match \"\(q)\"")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
        } else {
            Text("\(hits.count) results in \(content.title)")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)

            let hitTracks = hits.map(\.track)
            LazyVStack(spacing: 0) {
                ForEach(hits, id: \.track.id) { hit in
                    SearchHitRow(
                        hit: hit,
                        isCurrent: engine.current?.id == hit.track.id,
                        isPlaying: engine.isPlaying && engine.current?.id == hit.track.id,
                        onTap: { engine.play(hit.track, in: hitTracks, context: .search) },
                        onEllipsis: { detailTrack = hit.track }
                    )
                    Divider().background(Theme.hair)
                        .padding(.leading, Theme.Layout.rowSeparatorInset)
                }
            }
        }
    }

    // MARK: - Highlight wash helper

    @ViewBuilder
    private func highlightBackground(for track: Track) -> some View {
        if nav.highlightTrackId == track.id {
            Theme.accent.opacity(0.18)
                .animation(.easeOut(duration: 0.3), value: nav.highlightTrackId)
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

// MARK: - SearchHitRow

/// A row for scoped search hits — shows track title, "{artist} · {pathLabel}", and LUFS.
/// Visually mirrors NMRow but the subtitle shows path context instead of album.
private struct SearchHitRow: View {
    let hit: SearchHit
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var onTap: () -> Void = {}
    var onEllipsis: () -> Void = {}

    @State private var bins: [WaveBin] = []

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: hit.track.artworkData, size: 46, radius: Theme.Radius.albumRow)
                .overlay {
                    if isCurrent {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: isPlaying ? "waveform" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous))
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.track.title)
                    .font(Theme.sans(16, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                let subtitle = hit.pathLabel.isEmpty
                    ? hit.track.artist
                    : "\(hit.track.artist) · \(hit.pathLabel)"
                Text(subtitle)
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if !bins.isEmpty {
                NMMiniWave(bins: bins, bars: 22)
                    .frame(width: 42, height: 20).opacity(0.7)
                    .accessibilityHidden(true)
            }
            NMLufsValue(lufs: hit.track.integratedLUFS)
                .frame(minWidth: 44, alignment: .trailing)

            Button(action: onEllipsis) {
                Image(systemName: "ellipsis")
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rowEllipsis")
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: hit.track.persistentModelID) {
            bins = await WaveformStore.shared.bins(for: hit.track) ?? []
        }
    }
}
