import Foundation
import Observation
import SwiftData

enum SmartEntry: Equatable { case allSongs }

/// The single nav-state object that drives the whole Library tab (handoff §02 `libNav`). Breadcrumbs,
/// back, tab re-tap, and Go-to-Source are just different ways of writing this. Owned by RootView and
/// injected, so any track context (playlist/queue/search/Now Playing) can re-drive it.
@MainActor
@Observable
final class LibraryNav {
    var smart: SmartEntry?
    var sourceId: String?
    var folderIds: [String] = []

    var isRoot: Bool { smart == nil && sourceId == nil }

    func reset() { smart = nil; sourceId = nil; folderIds = [] }
    func openAllSongs() { smart = .allSongs; sourceId = nil; folderIds = [] }
    func openSource(_ id: String) { smart = nil; sourceId = id; folderIds = [] }
    func openFolder(_ folderId: String) { folderIds.append(folderId) }

    /// Pop one level: a folder → its parent; at a source root → Library root.
    func up() {
        if !folderIds.isEmpty { folderIds.removeLast() }
        else { reset() }
    }

    /// Breadcrumb tap: keep the first `folderDepth` folder ids (0 = source root).
    func jumpTo(folderDepth: Int) {
        guard folderDepth >= 0, folderDepth < folderIds.count else {
            if folderDepth <= 0 { folderIds = [] }
            return
        }
        folderIds = Array(folderIds.prefix(folderDepth))
    }

    /// Go to Source (handoff §5.2): set the source + full path directly.
    func goToSource(sourceId: String, folderIds: [String]) {
        self.smart = nil; self.sourceId = sourceId; self.folderIds = folderIds
    }

    /// The row to flash after a Go-to-Source jump (handoff §5.2). LibraryScreen clears it after ~2.8 s.
    var highlightTrackId: UUID?
    /// Bumped to ask RootView to switch to the Library tab (Go-to-Source from a sheet/other tab).
    private(set) var switchToLibraryToken = 0

    /// Navigate to the folder holding `track` and flash it. Returns false (no-op) when the track's source
    /// is missing or not reachable (only `.connected` and `.offline` are reachable — handoff §5.2).
    @MainActor
    func goToSource(track: Track, index: LibraryIndex, ctx: ModelContext) -> Bool {
        guard let p = index.trackPath[track.id],
              let source = try? LibraryStore.source(id: p.sourceId, ctx) else { return false }
        let s = SourceState(rawValue: source.state)
        guard s == .connected || s == .offline else { return false }
        smart = nil; sourceId = p.sourceId; folderIds = p.folderIds
        let hid = track.id
        highlightTrackId = hid
        switchToLibraryToken += 1
        // Self-owned clear: survives tab switches (LibraryScreen unmount would cancel the view task).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            if self.highlightTrackId == hid { self.highlightTrackId = nil }
        }
        return true
    }
}
