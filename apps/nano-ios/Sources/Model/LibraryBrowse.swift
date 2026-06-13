import Foundation
import SwiftData

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
        if nav.smart == .allSongs { return BrowseContent(level: .allSongs) }
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
    // allSongsContent added in Task 4.
}
