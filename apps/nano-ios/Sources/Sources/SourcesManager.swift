import Foundation
import SwiftData

/// Connect / add-root / remove-root / disconnect over the SwiftData store, then rebuild the index. The
/// picker + enumeration are done by the caller (provider); this turns their output into rows (handoff §06/§08).
@MainActor
final class SourcesManager {
    private let ctx: ModelContext
    private let index: LibraryIndex
    init(ctx: ModelContext, index: LibraryIndex) { self.ctx = ctx; self.index = index }

    /// Create the Source row (state .noRoots until a root is added).
    func connect(kind: SourceKind, authRef: String? = nil) {
        if (try? LibraryStore.source(id: kind.rawValue, ctx)) ?? nil != nil { return }
        ctx.insert(Source(id: kind.rawValue, kind: kind, state: .noRoots, authRef: authRef))
        index.rebuild(from: ctx)
    }

    /// Materialize an enumeration into FolderNode/Track rows under a new RootFolder, then rebuild.
    func applyEnumeration(_ result: EnumerationResult, sourceId: String, rootName: String,
                          rootNodeId: String, rootBookmark: Data?, providerFolderId: String? = nil) {
        let kind = SourceKind(rawValue: ((try? LibraryStore.source(id: sourceId, ctx)) ?? nil)?.kind ?? "") ?? .local
        // Persist a TrackDescriptor → Track row (id-mapped so FolderNode.trackIds can reference UUIDs).
        var idMap: [String: UUID] = [:]
        for td in result.tracks {
            let t = Track(title: td.title, artist: td.artist, album: td.album,
                          sourceKind: kind.rawValue, bookmark: td.bookmark, displayPath: kind.label,
                          durationSec: td.durationSec, format: td.format,
                          sourceId: sourceId, providerFileId: td.providerFileId)
            ctx.insert(t); idMap[td.id] = t.id
        }
        for fd in result.folders {
            let node = FolderNode(id: fd.id, sourceId: sourceId, name: fd.name, parentId: fd.parentId,
                                  childFolderIds: fd.childFolderIds,
                                  trackIds: fd.trackIds.compactMap { idMap[$0] }, lastIndexed: .init())
            ctx.insert(node)
            for tid in fd.trackIds {
                if let uuid = idMap[tid], let tr = try? LibraryStore.track(id: uuid, ctx) {
                    tr.folderId = fd.id
                }
            }
        }
        ctx.insert(RootFolder(sourceId: sourceId, name: rootName, providerFolderId: providerFolderId,
                              nodeId: rootNodeId, bookmark: rootBookmark))
        if let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil {
            s.state = SourceState.connected.rawValue
        }
        index.rebuild(from: ctx)
    }

    func removeRoot(_ root: RootFolder) {
        let sourceId = root.sourceId
        if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
        ctx.delete(root)
        // If that was the last root, mark the source noRoots.
        if (try? LibraryStore.rootFolders(of: sourceId, ctx))?.isEmpty ?? true,
           let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil {
            s.state = SourceState.noRoots.rawValue
        }
        index.rebuild(from: ctx)
    }

    func disconnect(sourceId: String) {
        for root in (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? [] {
            if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
            ctx.delete(root)
        }
        if let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil { ctx.delete(s) }
        index.rebuild(from: ctx)
    }

    /// Delete a root's FolderNode subtree (the cache). Track ROWS are kept (playlists may reference them);
    /// they just stop being reachable once their nodes/source are gone.
    private func deleteSubtree(nodeId: String, sourceId: String) {
        guard let node = try? LibraryStore.folderNode(id: nodeId, ctx) else { return }
        for childId in node.childFolderIds { deleteSubtree(nodeId: childId, sourceId: sourceId) }
        ctx.delete(node)
    }
}
