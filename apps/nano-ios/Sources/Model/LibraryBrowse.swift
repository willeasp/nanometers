import Foundation
import SwiftData

struct SearchHit: Equatable { var track: Track; var pathLabel: String
    static func == (a: SearchHit, b: SearchHit) -> Bool { a.track.id == b.track.id && a.pathLabel == b.pathLabel } }

/// A pure, render-ready snapshot of the Library tab for the current `LibraryNav` (handoff §03). Views
/// render this; all SwiftData reads happen here so the logic is unit-testable.
struct BrowseContent {
    enum Level { case root, allSongs, folder }
    struct Crumb: Equatable { var label: String; var folderDepth: Int }   // folderDepth for LibraryNav.jumpTo

    var level: Level
    var title: String = ""
    var crumbs: [Crumb] = []
    var sources: [Source] = []          // root level
    var allSongsCount: Int = 0          // root level
    var folders: [FolderNode] = []      // folder level (sub-folders)
    var tracks: [Track] = []            // folder/allSongs level (direct tracks)
    var playAll: [Track] = []           // recursive, depth-first, for the header Play All
    var sourceTint: String = "#9AA1B0"
    var showsPlayAll: Bool { !playAll.isEmpty }
}

/// An immutable address inside the Library — the part of `LibraryNav` that decides *what* renders.
/// Each `NavigationStack` level holds its own `NavLocation` so it renders independently of the live nav.
struct NavLocation: Equatable {
    var smart: SmartEntry?
    var sourceId: String?
    var folderIds: [String]
    init(smart: SmartEntry? = nil, sourceId: String? = nil, folderIds: [String] = []) {
        self.smart = smart; self.sourceId = sourceId; self.folderIds = folderIds
    }
    static let root = NavLocation()
}

enum LibraryBrowse {
    @MainActor
    static func content(for nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        content(at: NavLocation(smart: nav.smart, sourceId: nav.sourceId, folderIds: nav.folderIds),
                index: index, ctx: ctx)
    }

    @MainActor
    static func content(at loc: NavLocation, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        if loc.smart == .allSongs { return allSongsContent(index: index, ctx: ctx) }
        if let sourceId = loc.sourceId { return folderContent(sourceId: sourceId, folderIds: loc.folderIds, index: index, ctx: ctx) }
        return rootContent(index: index, ctx: ctx)
    }

    @MainActor
    private static func rootContent(index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let all = (try? LibraryStore.allSources(ctx)) ?? []
        // Show non-disconnected sources that have ≥1 root → hides `disconnected` and connected-zero-roots (§8).
        let visible = all.filter {
            SourceState(rawValue: $0.state) != .disconnected
                && !((try? LibraryStore.rootFolders(of: $0.id, ctx))?.isEmpty ?? true)
        }
        var c = BrowseContent(level: .root, title: "Library")
        c.sources = visible
        c.allSongsCount = index.reachableTrackIds.count
        return c
    }

    @MainActor
    private static func folderContent(sourceId: String, folderIds: [String], index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let source = try? LibraryStore.source(id: sourceId, ctx)
        let kind = source.flatMap { SourceKind(rawValue: $0.kind) } ?? .local
        var c = BrowseContent(level: .folder)
        c.sourceTint = kind.tintHex
        var crumbs = [BrowseContent.Crumb(label: kind.short, folderDepth: -1)]   // first crumb = source root

        if folderIds.isEmpty {
            // Source root: list the source's root folders.
            c.title = source?.label ?? kind.label
            let roots = (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? []
            c.folders = roots.compactMap { rootNode(for: $0, ctx: ctx) }
            c.tracks = []
            c.playAll = c.folders.flatMap { flatten($0, ctx: ctx) }
            c.crumbs = crumbs
            return c
        }

        // Inside a folder: title + crumbs from the path; sub-folders + direct tracks; recursive play-all.
        var node: FolderNode?
        for (depth, fid) in folderIds.enumerated() {
            node = try? LibraryStore.folderNode(id: fid, ctx)
            crumbs.append(.init(label: node?.name ?? "…", folderDepth: depth))
        }
        c.title = node?.name ?? kind.label
        c.crumbs = crumbs
        if let node {
            c.folders = (try? LibraryStore.childFolders(of: node.id, ctx)) ?? []
            c.tracks = (try? LibraryStore.tracksInFolder(id: node.id, ctx)) ?? []
            c.playAll = flatten(node, ctx: ctx)
        }
        return c
    }

    /// The FolderNode that backs a root folder: cloud roots resolve by `providerFolderId`, local roots by
    /// the stable `nodeId` persisted on the RootFolder (matches the hardened `LibraryIndex.rootNode`).
    @MainActor
    static func rootNode(for root: RootFolder, ctx: ModelContext) -> FolderNode? {
        guard let id = root.providerFolderId ?? root.nodeId else { return nil }
        return try? LibraryStore.folderNode(id: id, ctx)
    }

    /// Depth-first descendant tracks (handoff §3.2 Play All), in folder then child order. `visited`
    /// guards against a cyclic/DAG cache (same guarantee as `LibraryIndex.walk`).
    @MainActor
    static func flatten(_ node: FolderNode, ctx: ModelContext, visited: inout Set<String>) -> [Track] {
        guard visited.insert(node.id).inserted else { return [] }
        var out = (try? LibraryStore.tracksInFolder(id: node.id, ctx)) ?? []
        for childId in node.childFolderIds {
            if let child = try? LibraryStore.folderNode(id: childId, ctx) {
                out += flatten(child, ctx: ctx, visited: &visited)
            }
        }
        return out
    }

    /// Convenience: flatten with a fresh cycle-guard set, deduplicated by id (first-occurrence order).
    @MainActor
    static func flatten(_ node: FolderNode, ctx: ModelContext) -> [Track] {
        var visited = Set<String>()
        return dedupeByID(flatten(node, ctx: ctx, visited: &visited))
    }

    /// Remove duplicate tracks, keeping the first occurrence (stable, id-keyed).
    static func dedupeByID(_ tracks: [Track]) -> [Track] {
        var seen = Set<UUID>(); return tracks.filter { seen.insert($0.id).inserted }
    }
    @MainActor
    private static func allSongsContent(index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let reachable = index.reachableTrackIds
        let tracks = ((try? LibraryStore.allTracks(ctx)) ?? []).filter { reachable.contains($0.id) }
        var c = BrowseContent(level: .allSongs, title: "All Songs")
        c.tracks = tracks
        c.playAll = tracks
        c.sourceTint = Theme.accentHex
        return c
    }

    /// A track is playable if it has a local file handle (bundled/imported/enumerated) OR its cloud source
    /// is currently reachable. Orphaned cloud tracks (source disconnected) are unavailable (handoff §10).
    @MainActor
    static func isAvailable(_ track: Track, index: LibraryIndex) -> Bool {
        if track.bundledName != nil || track.bookmark != nil || track.folderBookmark != nil { return true }
        return index.reachableTrackIds.contains(track.id)
    }

    /// Filter the already-recursive `scope` tracks by `query` (case-insensitive over title/artist/album),
    /// each hit annotated with its folder path. Empty/whitespace query → no hits (search is opt-in).
    @MainActor
    static func search(_ scope: [Track], query: String, nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> [SearchHit] {
        search(scope, query: query, scopeFolderIds: nav.folderIds, allSongs: nav.smart == .allSongs, index: index, ctx: ctx)
    }

    @MainActor
    static func search(_ scope: [Track], query: String, scopeFolderIds: [String], allSongs: Bool, index: LibraryIndex, ctx: ModelContext) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let filtered = dedupeByID(scope.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        })
        return filtered.map { SearchHit(track: $0, pathLabel: relativePath(for: $0, scopeFolderIds: scopeFolderIds, allSongs: allSongs, index: index, ctx: ctx)) }
    }

    /// Folder path for a hit. Under a source scope: path RELATIVE to the current scope (strips the scope
    /// folder prefix). Under All Songs: "SourceShort / Folder / Sub" (handoff §04).
    /// Names resolved from the cached FolderNodes (offline-safe).
    @MainActor
    static func relativePath(for track: Track, scopeFolderIds: [String] = [], allSongs: Bool, index: LibraryIndex, ctx: ModelContext) -> String {
        guard let p = index.trackPath[track.id] else { return "" }
        var folderIds = p.folderIds
        if !allSongs && !scopeFolderIds.isEmpty {
            // Strip the current scope prefix so the label is relative to where the user is searching.
            var i = 0
            while i < scopeFolderIds.count, i < folderIds.count, scopeFolderIds[i] == folderIds[i] { i += 1 }
            folderIds = Array(folderIds.dropFirst(i))
        }
        let names = folderIds.compactMap { (try? LibraryStore.folderNode(id: $0, ctx))?.name }
        if allSongs {
            let short = (try? LibraryStore.source(id: p.sourceId, ctx)).flatMap { SourceKind(rawValue: $0.kind)?.short } ?? ""
            return ([short] + p.folderIds.compactMap { (try? LibraryStore.folderNode(id: $0, ctx))?.name }).filter { !$0.isEmpty }.joined(separator: " / ")
        }
        return names.joined(separator: " / ")
    }
}
