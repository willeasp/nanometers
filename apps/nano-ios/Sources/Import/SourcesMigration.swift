import Foundation
import SwiftData

/// One-shot, idempotent data migration (handoff §11): pre-existing tracks predate the Source model, so
/// attach them to a seeded "On My iPhone" local source under a single synthetic root, keeping them
/// reachable in the new folder-browser Library. Runs at launch after `DemoSeed`.
enum SourcesMigration {
    /// Stable id of the synthetic local root FolderNode the migration creates; tracks link to it by id.
    static let localRootNodeId = "local-root"

    @MainActor
    static func runIfNeeded(_ ctx: ModelContext) {
        let existingLocal = (try? LibraryStore.source(id: "local", ctx)) ?? nil
        guard existingLocal == nil else { return }

        let source = Source(id: "local", kind: .local, state: .connected)
        ctx.insert(source)
        let root = RootFolder(sourceId: "local", name: SourceKind.local.label, nodeId: localRootNodeId)
        ctx.insert(root)

        let existing = (try? LibraryStore.allTracks(ctx)) ?? []
        let localTracks = existing.filter { $0.sourceKind == SourceKind.local.rawValue }
        for t in localTracks {
            t.sourceId = "local"
            t.folderId = localRootNodeId
        }
        let node = FolderNode(id: localRootNodeId, sourceId: "local",
                              name: SourceKind.local.label, parentId: nil,
                              childFolderIds: [], trackIds: localTracks.map(\.id),
                              lastIndexed: .init())
        ctx.insert(node)
    }
}
