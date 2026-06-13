import Foundation
import SwiftData
import Observation

/// The one place reachability, recursive counts, and trackId→path are derived (handoff §06). Rebuilt on
/// connect/disconnect/add-root/remove-root and after enumeration. Powers All Songs, source/folder
/// subtitles, scoped search, and Go-to-Source. A track is *reachable* only under a non-disconnected
/// source's added root.
@MainActor
@Observable
final class LibraryIndex {
    struct Counts: Equatable { var folders: Int = 0; var tracks: Int = 0 }

    private(set) var reachableTrackIds: Set<UUID> = []
    private(set) var sourceCounts: [String: Counts] = [:]
    private(set) var folderCounts: [String: Counts] = [:]
    private(set) var trackPath: [UUID: (sourceId: String, folderIds: [String])] = [:]

    func rebuild(from ctx: ModelContext) {
        var reachable: Set<UUID> = []
        var sCounts: [String: Counts] = [:]
        var fCounts: [String: Counts] = [:]
        var paths: [UUID: (String, [String])] = [:]

        let sources = (try? LibraryStore.allSources(ctx)) ?? []
        let allNodes = (try? ctx.fetch(FetchDescriptor<FolderNode>())) ?? []
        let nodesById = Dictionary(uniqueKeysWithValues: allNodes.map { ($0.id, $0) })

        for source in sources where SourceState(rawValue: source.state) != .disconnected {
            let roots = (try? LibraryStore.rootFolders(of: source.id, ctx)) ?? []
            var srcCount = Counts()
            for root in roots {
                guard let rootNode = rootNode(for: root, in: nodesById) else { continue }
                let c = walk(rootNode, source: source.id, prefix: [],
                             nodesById: nodesById,
                             reachable: &reachable, fCounts: &fCounts, paths: &paths)
                srcCount.folders += c.folders
                srcCount.tracks += c.tracks
            }
            sCounts[source.id] = srcCount
        }
        reachableTrackIds = reachable
        sourceCounts = sCounts
        folderCounts = fCounts
        trackPath = paths.reduce(into: [:]) { $0[$1.key] = ($1.value.0, $1.value.1) }
    }

    /// A root's FolderNode: cloud roots match by `providerFolderId`; local roots use the migration's
    /// derived node id. Falls back to any node whose id equals the root's providerFolderId.
    private func rootNode(for root: RootFolder, in nodesById: [String: FolderNode]) -> FolderNode? {
        if let pid = root.providerFolderId, let n = nodesById[pid] { return n }
        // Local root: the migration created a node id "local-root" (no providerFolderId).
        return nodesById.values.first { $0.sourceId == root.sourceId && $0.parentId == nil }
    }

    /// Depth-first accumulate: counts this node as one folder, adds its direct tracks, recurses children.
    private func walk(_ node: FolderNode, source: String, prefix: [String],
                      nodesById: [String: FolderNode],
                      reachable: inout Set<UUID>, fCounts: inout [String: Counts],
                      paths: inout [UUID: (String, [String])]) -> Counts {
        let here = prefix + [node.id]
        var folders = 1
        var tracks = node.trackIds.count
        for tid in node.trackIds {
            reachable.insert(tid)
            paths[tid] = (source, here)
        }
        for childId in node.childFolderIds {
            guard let child = nodesById[childId] else { continue }
            let c = walk(child, source: source, prefix: here, nodesById: nodesById,
                         reachable: &reachable, fCounts: &fCounts, paths: &paths)
            folders += c.folders
            tracks += c.tracks
        }
        fCounts[node.id] = Counts(folders: folders - 1, tracks: tracks)  // exclude self from folder count
        return Counts(folders: folders, tracks: tracks)
    }
}
