import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var album: String

    // Source / location (handoff §04). `bookmark` is nil for the demo seed (no file).
    var sourceKind: String
    var bookmark: Data?
    var folderBookmark: Data?
    var displayPath: String

    // Audio metadata, read once on import.
    var durationSec: Double
    var format: String
    var sampleRate: String
    var bitDepth: Int?            // PCM bit depth (FLAC/WAV/AIFF); nil for lossy/unknown. Title format line.
    var hasEmbeddedArt: Bool
    var artworkData: Data?        // small embedded artwork, if any
    var bundledName: String?      // resource filename for tracks that ship in the app bundle
    var artworkTintHex: String?   // computed in Phase 4 (Now Playing gradient)

    // Loudness — the integrated value is analyzed in Phase 3; nil until then.
    var integratedLUFS: Double?

    // User state
    var isLoved: Bool
    var dateAdded: Date

    // Waveform cache pointer (Phase 3).
    var waveformCacheKey: String

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        sourceKind: String = SourceKind.local.rawValue,
        bookmark: Data? = nil,
        folderBookmark: Data? = nil,
        displayPath: String = "On My iPhone",
        durationSec: Double = 0,
        format: String = "",
        sampleRate: String = "",
        bitDepth: Int? = nil,
        hasEmbeddedArt: Bool = false,
        artworkData: Data? = nil,
        bundledName: String? = nil,
        integratedLUFS: Double? = nil,
        isLoved: Bool = false,
        dateAdded: Date = .init(),
        waveformCacheKey: String = ""
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.sourceKind = sourceKind
        self.bookmark = bookmark
        self.folderBookmark = folderBookmark
        self.displayPath = displayPath
        self.durationSec = durationSec
        self.format = format
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.hasEmbeddedArt = hasEmbeddedArt
        self.artworkData = artworkData
        self.bundledName = bundledName
        self.artworkTintHex = nil
        self.integratedLUFS = integratedLUFS
        self.isLoved = isLoved
        self.dateAdded = dateAdded
        self.waveformCacheKey = waveformCacheKey
    }
}
