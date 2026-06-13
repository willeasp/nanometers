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
            var srcFolders = 0
            var srcTracks = Set<UUID>()
            for root in roots {
                guard let rootNode = rootNode(for: root, in: nodesById) else { continue }
                var visited = Set<String>()
                let c = walk(rootNode, source: source.id, prefix: [], nodesById: nodesById, visited: &visited,
                             reachable: &reachable, fCounts: &fCounts, paths: &paths)
                srcFolders += c.folders
                srcTracks.formUnion(c.trackIds)
            }
            sCounts[source.id] = Counts(folders: srcFolders, tracks: srcTracks.count)
        }
        reachableTrackIds = reachable
        sourceCounts = sCounts
        folderCounts = fCounts
        trackPath = paths.reduce(into: [:]) { $0[$1.key] = ($1.value.0, $1.value.1) }
    }

    /// The FolderNode backing a root: cloud roots resolve by `providerFolderId`, local roots by the
    /// stable `nodeId` persisted on the RootFolder. Returns nil when the node isn't indexed yet
    /// (a not-yet-enumerated root correctly contributes nothing) — no parentless-node guessing.
    private func rootNode(for root: RootFolder, in nodesById: [String: FolderNode]) -> FolderNode? {
        guard let id = root.providerFolderId ?? root.nodeId else { return nil }
        return nodesById[id]
    }

    /// Depth-first accumulate. `visited` guards against cycles / DAG re-entry within one root walk.
    /// Returns the subtree's folder count (incl. self) and its DISTINCT track ids.
    private func walk(_ node: FolderNode, source: String, prefix: [String],
                      nodesById: [String: FolderNode], visited: inout Set<String>,
                      reachable: inout Set<UUID>, fCounts: inout [String: Counts],
                      paths: inout [UUID: (String, [String])]) -> (folders: Int, trackIds: Set<UUID>) {
        guard visited.insert(node.id).inserted else { return (0, []) }   // cycle / re-visit guard
        let here = prefix + [node.id]
        var folders = 1
        var subtree = Set<UUID>()
        for tid in node.trackIds {
            reachable.insert(tid)
            if paths[tid] == nil { paths[tid] = (source, here) }   // first-walk-wins (deterministic Go-to-Source)
            subtree.insert(tid)
        }
        for childId in node.childFolderIds {
            guard let child = nodesById[childId] else { continue }   // dangling child id → skip
            let c = walk(child, source: source, prefix: here, nodesById: nodesById, visited: &visited,
                         reachable: &reachable, fCounts: &fCounts, paths: &paths)
            folders += c.folders
            subtree.formUnion(c.trackIds)
        }
        fCounts[node.id] = Counts(folders: folders - 1, tracks: subtree.count)   // folders=descendants; tracks=distinct
        return (folders, subtree)
    }
}
