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
    /// Upserts Tracks keyed on (sourceId, providerFileId) — re-adding the same root produces no
    /// duplicate Track rows, making the operation idempotent (FIX 3).
    func applyEnumeration(_ result: EnumerationResult, sourceId: String, rootName: String,
                          rootNodeId: String, rootBookmark: Data?, providerFolderId: String? = nil) {
        let kind = SourceKind(rawValue: ((try? LibraryStore.source(id: sourceId, ctx)) ?? nil)?.kind ?? "") ?? .local

        // Build a lookup of existing tracks by (sourceId, providerFileId) for upsert.
        let existingTracks = (try? LibraryStore.allTracksUnsorted(ctx)) ?? []
        var existingByKey: [String: Track] = [:]
        for t in existingTracks {
            guard let sid = t.sourceId, let pfid = t.providerFileId, sid == sourceId else { continue }
            existingByKey[pfid] = t
        }

        // Upsert: reuse an existing Track row if (sourceId, providerFileId) matches; insert otherwise.
        var idMap: [String: UUID] = [:]
        for td in result.tracks {
            let pfid = td.providerFileId ?? td.id
            if let existing = existingByKey[pfid] {
                // Update mutable metadata but keep the existing UUID so playlist refs stay valid.
                existing.title = td.title
                existing.artist = td.artist
                existing.album = td.album
                existing.format = td.format
                existing.durationSec = td.durationSec
                existing.folderBookmark = rootBookmark
                existing.providerFileId = pfid
                idMap[td.id] = existing.id
            } else {
                let t = Track(title: td.title, artist: td.artist, album: td.album,
                              sourceKind: kind.rawValue, bookmark: td.bookmark,
                              folderBookmark: rootBookmark, displayPath: kind.label,
                              durationSec: td.durationSec, format: td.format,
                              sourceId: sourceId, providerFileId: pfid)
                ctx.insert(t)
                idMap[td.id] = t.id
            }
        }
        for fd in result.folders {
            // Upsert FolderNode too: if a node with this id already exists (from a prior enumeration
            // of the same root), update it in place to avoid duplicate nodes.
            if let existing = try? LibraryStore.folderNode(id: fd.id, ctx) {
                existing.name = fd.name
                existing.parentId = fd.parentId
                existing.childFolderIds = fd.childFolderIds
                existing.trackIds = fd.trackIds.compactMap { idMap[$0] }
                existing.lastIndexed = .init()
            } else {
                let node = FolderNode(id: fd.id, sourceId: sourceId, name: fd.name, parentId: fd.parentId,
                                      childFolderIds: fd.childFolderIds,
                                      trackIds: fd.trackIds.compactMap { idMap[$0] }, lastIndexed: .init())
                ctx.insert(node)
            }
            for tid in fd.trackIds {
                if let uuid = idMap[tid], let tr = try? LibraryStore.track(id: uuid, ctx) {
                    tr.folderId = fd.id
                }
            }
        }
        // Only insert a new RootFolder if one for this root doesn't already exist.
        let existingRoots = (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? []
        let rootAlreadyExists = existingRoots.contains {
            ($0.providerFolderId ?? $0.nodeId) == (providerFolderId ?? rootNodeId)
        }
        if !rootAlreadyExists {
            ctx.insert(RootFolder(sourceId: sourceId, name: rootName, providerFolderId: providerFolderId,
                                  nodeId: rootNodeId, bookmark: rootBookmark))
        }
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
