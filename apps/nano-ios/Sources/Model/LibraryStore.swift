import Foundation
import SwiftData

/// Stateless query/mutation helpers over the SwiftData context. Keeps ordering logic (which lives in
/// `Playlist.itemIDs`) in one tested place, out of the views.
enum LibraryStore {
    static func allTracks(_ ctx: ModelContext) throws -> [Track] {
        try ctx.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))
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
        let byID = Dictionary(uniqueKeysWithValues: try allTracks(ctx).map { ($0.id, $0) })
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
}
