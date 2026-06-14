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

enum LibraryBrowse {
    @MainActor
    static func content(for nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        if nav.smart == .allSongs { return allSongsContent(index: index, ctx: ctx) }
        if let sourceId = nav.sourceId { return folderContent(sourceId: sourceId, nav: nav, index: index, ctx: ctx) }
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
    private static func folderContent(sourceId: String, nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let source = try? LibraryStore.source(id: sourceId, ctx)
        let kind = source.flatMap { SourceKind(rawValue: $0.kind) } ?? .local
        var c = BrowseContent(level: .folder)
        c.sourceTint = kind.tintHex
        var crumbs = [BrowseContent.Crumb(label: kind.short, folderDepth: -1)]   // first crumb = source root

        if nav.folderIds.isEmpty {
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
        for (depth, fid) in nav.folderIds.enumerated() {
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

    /// Convenience: flatten with a fresh cycle-guard set.
    @MainActor
    static func flatten(_ node: FolderNode, ctx: ModelContext) -> [Track] {
        var visited = Set<String>()
        return flatten(node, ctx: ctx, visited: &visited)
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

    /// Filter the already-recursive `scope` tracks by `query` (case-insensitive over title/artist/album),
    /// each hit annotated with its folder path. Empty/whitespace query → no hits (search is opt-in).
    @MainActor
    static func search(_ scope: [Track], query: String, nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return scope.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        }.map { SearchHit(track: $0, pathLabel: relativePath(for: $0, allSongs: nav.smart == .allSongs, index: index, ctx: ctx)) }
    }

    /// Folder path for a hit. Under a source scope: "Folder / Sub" (no source name). Under All Songs:
    /// "SourceShort / Folder / Sub" (handoff §04). Names resolved from the cached FolderNodes (offline-safe).
    @MainActor
    static func relativePath(for track: Track, allSongs: Bool, index: LibraryIndex, ctx: ModelContext) -> String {
        guard let p = index.trackPath[track.id] else { return "" }
        let names = p.folderIds.compactMap { (try? LibraryStore.folderNode(id: $0, ctx))?.name }
        if allSongs {
            let short = (try? LibraryStore.source(id: p.sourceId, ctx)).flatMap { SourceKind(rawValue: $0.kind)?.short } ?? ""
            return ([short] + names).filter { !$0.isEmpty }.joined(separator: " / ")
        }
        return names.joined(separator: " / ")
    }
}
