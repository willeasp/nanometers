import Foundation
import Observation

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
}
