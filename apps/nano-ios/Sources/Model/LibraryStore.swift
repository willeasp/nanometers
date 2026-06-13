import Foundation
import SwiftData

/// Stateless query/mutation helpers over the SwiftData context. Keeps ordering logic (which lives in
/// `Playlist.itemIDs`) in one tested place, out of the views.
enum LibraryStore {
    static func allTracks(_ ctx: ModelContext) throws -> [Track] {
        try ctx.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))
    }

    /// Unsorted fetch for id-keyed resolution paths that re-impose their own order (avoids a wasted sort).
    static func allTracksUnsorted(_ ctx: ModelContext) throws -> [Track] {
        try ctx.fetch(FetchDescriptor<Track>())
    }

    static func track(id: UUID, _ ctx: ModelContext) throws -> Track? {
        var d = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    static func allPlaylists(_ ctx: ModelContext) throws -> [Playlist] {
        try ctx.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.dateCreated, order: .reverse)]))
    }

    /// Resolve a playlist's ordered tracks, skipping any dangling ids.
    static func tracks(in pl: Playlist, _ ctx: ModelContext) throws -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: try allTracksUnsorted(ctx).map { ($0.id, $0) })
        return pl.itemIDs.compactMap { byID[$0] }
    }

    static func append(_ track: Track, to pl: Playlist) {
        guard !pl.itemIDs.contains(track.id) else { return }
        pl.itemIDs.append(track.id)
    }

    static func move(in pl: Playlist, fromOffsets: IndexSet, toOffset: Int) {
        pl.itemIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    static func remove(in pl: Playlist, atOffsets: IndexSet) {
        pl.itemIDs.remove(atOffsets: atOffsets)
    }

    static func allSources(_ ctx: ModelContext) throws -> [Source] {
        try ctx.fetch(FetchDescriptor<Source>(sortBy: [SortDescriptor(\.canonicalOrder)]))
    }

    static func source(id: String, _ ctx: ModelContext) throws -> Source? {
        var d = FetchDescriptor<Source>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    static func rootFolders(of sourceId: String, _ ctx: ModelContext) throws -> [RootFolder] {
        try ctx.fetch(FetchDescriptor<RootFolder>(
            predicate: #Predicate { $0.sourceId == sourceId },
            sortBy: [SortDescriptor(\.dateAdded)]))
    }

    static func folderNode(id: String, _ ctx: ModelContext) throws -> FolderNode? {
        var d = FetchDescriptor<FolderNode>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    static func childFolders(of parentId: String, _ ctx: ModelContext) throws -> [FolderNode] {
        try ctx.fetch(FetchDescriptor<FolderNode>(predicate: #Predicate { $0.parentId == parentId }))
    }

    /// Resolve a folder's direct tracks in stored order, skipping dangling ids.
    static func tracksInFolder(id: String, _ ctx: ModelContext) throws -> [Track] {
        guard let node = try folderNode(id: id, ctx) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: try allTracksUnsorted(ctx).map { ($0.id, $0) })
        return node.trackIds.compactMap { byID[$0] }
    }
}
