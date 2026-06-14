import SwiftUI
import SwiftData
import UIKit

/// The Library tab. A real `NavigationStack` drives the drill-down (root → source → folder → …) so each
/// level gets native push/pop animation and the interactive left-to-right swipe-back — matching the
/// Playlists tab. The stack's path is `LibraryNav.routePath`, so breadcrumb jumps, tab re-tap (reset),
/// and Go-to-Source still drive navigation by mutating `nav`; they now *animate* instead of insta-cutting.
///
/// The system nav bar is hidden on every level to keep the handoff's bespoke chrome (big in-content
/// titles, custom back-link rows, mono breadcrumb). Hiding the bar normally kills the edge-swipe gesture,
/// so `interactiveSwipeBack()` reinstates it by owning the nav controller's `interactivePopGestureRecognizer`.
struct LibraryScreen: View {
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index
    @Query private var sources: [Source]
    var onSearch: () -> Void = {}

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.routePath) {
            LibraryRootLevel(onSearch: onSearch)
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .allSongs:
                        LibraryAllSongsLevel()
                    case .source(let sid):
                        LibraryFolderLevel(location: NavLocation(sourceId: sid, folderIds: []))
                    case .folder(let sid, let ids):
                        LibraryFolderLevel(location: NavLocation(sourceId: sid, folderIds: ids))
                    }
                }
        }
        .tint(Theme.accent)
        .background(Theme.bg)
        // Task 6 nav bounce: if the source the user is browsing has been disconnected/removed, or a folder
        // node in the path no longer exists, pop back gracefully. Mutating nav reshapes routePath → animates.
        .onChange(of: sources) { _, newSources in validateNav(sources: newSources) }
        .onChange(of: index.sourceCounts) { _, _ in validateNav(sources: sources) }
    }

    /// Validate that the current nav state still resolves; pop to the nearest valid ancestor otherwise.
    private func validateNav(sources: [Source]) {
        guard !nav.isRoot else { return }
        if nav.smart != nil { return }   // All Songs — always valid.

        if let sid = nav.sourceId, !sources.contains(where: { $0.id == sid }) {
            nav.reset(); return
        }
        if !nav.folderIds.isEmpty {
            var validDepth = 0
            for folderId in nav.folderIds {
                if (try? LibraryStore.folderNode(id: folderId, ctx)) != nil { validDepth += 1 } else { break }
            }
            if validDepth < nav.folderIds.count { nav.jumpTo(folderDepth: validDepth) }
        }
    }
}

// MARK: - Root level

/// Library root: the "All Songs" entry + the connected sources. Taps mutate `nav`, which grows the stack
/// path and animates a push.
private struct LibraryRootLevel: View {
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index
    @State private var showSettings = false
    var onSearch: () -> Void = {}

    var body: some View {
        let content = LibraryBrowse.content(at: .root, index: index, ctx: ctx)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                    librarySectionHeader("Sources")
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

                Text("Manage sources & root folders in Settings")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 8)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveSwipeBack()
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }
}

// MARK: - Folder level (source root or a folder within it)

/// A pushed source/folder level. Renders the content for its *own* immutable `location` (never the live
/// nav), so it keeps showing the right thing while it sits mounted beneath a deeper level during a swipe.
/// Navigation actions (drill in / back / breadcrumb jump) mutate the shared `nav`; because this view is
/// always the top one when it's interactive, the live nav state equals `location`, so the relative
/// mutations (`openFolder`/`up`/`jumpTo`) land correctly and animate.
private struct LibraryFolderLevel: View {
    let location: NavLocation

    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index

    @State private var detailTrack: Track?
    @State private var searchActive = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    /// Short label for the current scope — source short at the source root, else the content title.
    private func scopeLabel(content: BrowseContent) -> String {
        if location.folderIds.isEmpty, let sid = location.sourceId,
           let source = try? LibraryStore.source(id: sid, ctx),
           let kind = SourceKind(rawValue: source.kind) {
            return kind.short
        }
        return content.title
    }

    var body: some View {
        let content = LibraryBrowse.content(at: location, index: index, ctx: ctx)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // (1) Back-link row: ‹ {destination} in Theme.accent
                    let backDestination = location.folderIds.isEmpty
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

                    // (3) Scoped search field
                    if searchActive {
                        scopedSearchField(label: scopeLabel(content: content))
                            .padding(.bottom, 6)
                    }

                    // (3b) Mono breadcrumb — below the title (handoff §3.2 order)
                    if !content.crumbs.isEmpty {
                        crumbTrail(crumbs: content.crumbs)
                            .padding(.bottom, 10)
                    }

                    if searchActive && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        ScopedSearchResults(
                            scope: content.playAll, query: searchQuery,
                            scopeFolderIds: location.folderIds, allSongs: false,
                            scopeLabel: scopeLabel(content: content),
                            onEllipsis: { detailTrack = $0 }
                        )
                    } else {
                        folderBody(content: content)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenMargin)
                .padding(.top, 8)
            }
            // Scroll to highlighted track (clear is owned by LibraryNav.goToSource).
            .task(id: nav.highlightTrackId) {
                guard let tid = nav.highlightTrackId else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(tid, anchor: .center) }
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveSwipeBack()
        .sheet(item: $detailTrack) { TrackContextSheet(track: $0) }
    }

    @ViewBuilder
    private func folderBody(content: BrowseContent) -> some View {
        // Play All / Play + Shuffle row
        if content.showsPlayAll {
            let playCtx = folderPlayContext(content: content)
            let playTitle = content.folders.isEmpty ? "Play" : "Play All"   // leaf folder → "Play"
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
            Text("This folder is empty.")
                .font(Theme.sans(15))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 48)
        } else {
            if !content.folders.isEmpty {
                let sectionTitle = location.folderIds.isEmpty ? "Root Folders" : "Folders"
                librarySectionHeader(sectionTitle)
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

            if !content.tracks.isEmpty {
                librarySectionHeader("Tracks")
                let rowCtx = PlayContext(kind: "PLAYING FROM", name: content.title)
                LazyVStack(spacing: 0) {
                    ForEach(content.tracks) { track in
                        NMRow(
                            track: track,
                            isCurrent: engine.current?.id == track.id,
                            isPlaying: engine.isPlaying && engine.current?.id == track.id,
                            onTap: { engine.play(track, in: content.tracks, context: rowCtx) },
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

        // Source-root footer
        if location.folderIds.isEmpty {
            Text("Add or manage root folders…")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func scopedSearchField(label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
            TextField("Search in \(label)", text: $searchQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .accessibilityIdentifier("scopedSearchField")
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
        .onAppear { searchFocused = true }
    }

    /// Inline mono breadcrumb trail (handoff §3.2). Ancestor crumbs tap to jump; last is inert.
    @ViewBuilder
    private func crumbTrail(crumbs: [BrowseContent.Crumb]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                let isLast = idx == crumbs.count - 1
                if idx > 0 {
                    Text(" / ").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                }
                if isLast {
                    Text(crumb.label)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text2)
                        .accessibilityIdentifier("crumb-\(crumb.label)")
                } else {
                    Button(crumb.label) { mapCrumb(crumb.folderDepth) }
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

    /// Map a breadcrumb `folderDepth` to a LibraryNav mutation (animated pop).
    private func mapCrumb(_ depth: Int) {
        if depth < 0 { nav.folderIds = [] } else { nav.jumpTo(folderDepth: depth + 1) }
    }

    @ViewBuilder
    private func highlightBackground(for track: Track) -> some View {
        if nav.highlightTrackId == track.id {
            Theme.accent.opacity(0.18)
                .animation(.easeOut(duration: 0.3), value: nav.highlightTrackId)
        }
    }

    private func folderPlayContext(content: BrowseContent) -> PlayContext {
        let sourceLabel: String
        if let sid = location.sourceId, let src = (try? LibraryStore.source(id: sid, ctx)) {
            sourceLabel = src.label
        } else {
            sourceLabel = content.title
        }
        return PlayContext(kind: "PLAYING FROM \(sourceLabel.uppercased())", name: content.title)
    }
}

// MARK: - All Songs level

private struct LibraryAllSongsLevel: View {
    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryNav.self) private var nav
    @Environment(LibraryIndex.self) private var index

    @State private var importing = false
    @State private var detailTrack: Track?
    @State private var searchActive = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let content = LibraryBrowse.content(at: NavLocation(smart: .allSongs), index: index, ctx: ctx)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header: back to Library + search toggle + import button
                    HStack {
                        Button(action: { nav.reset() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(Theme.sans(14, .semibold))
                                Text("Library").font(Theme.sans(15))
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

                    if searchActive {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                            TextField("Search in All Songs", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.text)
                                .autocorrectionDisabled()
                                .focused($searchFocused)
                                .accessibilityIdentifier("scopedSearchField")
                        }
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
                        .padding(.bottom, 8)
                        .onAppear { searchFocused = true }
                    }

                    if searchActive && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        ScopedSearchResults(
                            scope: content.playAll, query: searchQuery,
                            scopeFolderIds: [], allSongs: true,
                            scopeLabel: "All Songs",
                            onEllipsis: { detailTrack = $0 }
                        )
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
                                Divider().background(Theme.hair)
                                    .padding(.leading, Theme.Layout.rowSeparatorInset)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenMargin)
                .padding(.top, 8)
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveSwipeBack()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { _ = await TrackImporter.importFiles(urls, into: ctx) }
            }
        }
        .sheet(item: $detailTrack) { TrackContextSheet(track: $0) }
    }
}

// MARK: - Shared helpers

/// Micro-label section header — uppercase, bold, tight tracking, Theme.text3 (handoff §3.1).
fileprivate func librarySectionHeader(_ title: String) -> some View {
    Text(title)
        .font(Theme.sans(10.5, .bold))
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(Theme.text3)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
}

/// Scoped search results list — shared by the folder and All Songs levels.
private struct ScopedSearchResults: View {
    let scope: [Track]
    let query: String
    let scopeFolderIds: [String]
    let allSongs: Bool
    let scopeLabel: String
    var onEllipsis: (Track) -> Void = { _ in }

    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @Environment(LibraryIndex.self) private var index

    var body: some View {
        let hits = LibraryBrowse.search(scope, query: query, scopeFolderIds: scopeFolderIds,
                                        allSongs: allSongs, index: index, ctx: ctx)
        let q = query.trimmingCharacters(in: .whitespaces)

        if hits.isEmpty {
            Text("No tracks match \"\(q)\".")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
        } else {
            Text("\(hits.count) \(hits.count == 1 ? "result" : "results") in \(scopeLabel)")
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
                        onEllipsis: { onEllipsis(hit.track) }
                    )
                    Divider().background(Theme.hair)
                        .padding(.leading, Theme.Layout.rowSeparatorInset)
                }
            }
        }
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
                if hit.pathLabel.isEmpty {
                    Text(hit.track.artist)
                        .font(Theme.sans(13.5))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                } else {
                    (Text(hit.track.artist).foregroundStyle(Theme.text2)
                        + Text(" · \(hit.pathLabel)").foregroundStyle(Theme.text3))
                        .font(Theme.sans(13.5))
                        .lineLimit(1)
                }
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

// MARK: - Interactive swipe-back with a hidden nav bar

extension View {
    /// Re-enables the edge swipe-to-go-back gesture for a `NavigationStack` whose bar is hidden.
    /// Hiding the bar makes UIKit disable `interactivePopGestureRecognizer`; we reinstate it by owning
    /// its delegate and allowing the gesture whenever the stack has something to pop back to.
    func interactiveSwipeBack() -> some View { background(SwipeBackInstaller().frame(width: 0, height: 0)) }
}

private struct SwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Holder { Holder() }
    func updateUIViewController(_ vc: Holder, context: Context) {}

    /// A zero-size child controller that, once attached, takes ownership of the parent
    /// `UINavigationController`'s interactive pop gesture delegate.
    final class Holder: UIViewController {
        private let popDelegate = PopGestureDelegate()
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else { return }
            popDelegate.navigationController = nav
            gesture.delegate = popDelegate
            gesture.isEnabled = true
        }
    }

    final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only begin when there's a screen to pop back to (avoids a stuck swipe at the root).
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
