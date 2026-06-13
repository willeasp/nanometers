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
        if nav.sourceId != nil { return BrowseContent(level: .folder) }
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
    // folderContent + allSongsContent added in Tasks 3 & 4.
}
