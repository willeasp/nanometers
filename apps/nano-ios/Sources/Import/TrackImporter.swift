import Foundation
import SwiftData
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

/// Turns picked file URLs into `Track` rows: resolves a security-scoped bookmark, reads best-effort
/// metadata (title/artist/album/duration/artwork), and inserts. Handoff §04 (bookmarks) / §02
/// (artwork). Cloud availability + folder bookmarks are a v2 concern; we store what we can now.
enum TrackImporter {
    /// Returns the number of tracks imported.
    @MainActor
    static func importFiles(_ urls: [URL], into ctx: ModelContext) async -> Int {
        var count = 0
        for url in urls {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folderBookmark = try? url.deletingLastPathComponent()
                .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

            let meta = await readMetadata(url)
            let audio = audioFormat(url)        // real sample rate (kHz) + PCM bit depth from the decoder
            let track = Track(
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                sourceKind: SourceKind.local.rawValue,
                bookmark: bookmark,
                folderBookmark: folderBookmark,
                displayPath: SourceKind.local.label,
                durationSec: meta.duration,
                format: url.pathExtension.uppercased(),
                sampleRate: audio.rate,
                bitDepth: audio.bits,
                hasEmbeddedArt: meta.artwork != nil,
                artworkData: meta.artwork
            )
            ctx.insert(track)
            attachToLocalRoot(track, in: ctx)
            // Kick analysis so the waveform/LUFS are ready by the time the row appears.
            Task { @MainActor in await WaveformStore.shared.bins(for: track) }
            count += 1
        }
        return count
    }

    /// Stamp the local source ref and append to the migration's local root node so the track is
    /// reachable (All Songs / counts) the moment it appears.
    @MainActor
    private static func attachToLocalRoot(_ track: Track, in ctx: ModelContext) {
        track.sourceId = "local"
        track.folderId = SourcesMigration.localRootNodeId
        if let node = try? LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx) {
            node.trackIds.append(track.id)
        }
    }

    private struct Meta { var title: String; var artist: String; var album: String; var duration: Double; var artwork: Data? }

    /// Real sample rate (as a kHz string, e.g. "96" / "44.1") + source PCM bit depth.
    /// Best-effort: a non-audio file (tests) yields ("", nil); lossy files (MP3/AAC) have no source
    /// bit depth → nil. The on-disk ASBD reports `mBitsPerChannel` only for linear PCM (WAV/AIFF); for
    /// compressed-lossless (FLAC/ALAC) it's 0, so we query `kAudioFilePropertySourceBitDepth` via the
    /// AudioFile API — that's where the FLAC "24" actually lives (Phase A review finding).
    private static func audioFormat(_ url: URL) -> (rate: String, bits: Int?) {
        guard let af = try? AVAudioFile(forReading: url) else { return ("", nil) }
        let asbd = af.fileFormat.streamDescription.pointee
        let rate = khz(asbd.mSampleRate)
        let pcmBits = Int(asbd.mBitsPerChannel)
        if pcmBits > 0 { return (rate, pcmBits) }     // linear PCM (WAV/AIFF)
        return (rate, sourceBitDepth(url))            // compressed: FLAC/ALAC source depth, else nil
    }

    /// `kAudioFilePropertySourceBitDepth` (AudioFile API): the source bit depth even for compressed
    /// containers. Positive = integer PCM bits; negative = floating-point (report its magnitude); the
    /// property is absent for truly lossy sources → nil.
    private static func sourceBitDepth(_ url: URL) -> Int? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fid = fileID else { return nil }
        defer { AudioFileClose(fid) }
        var depth: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioFileGetProperty(fid, kAudioFilePropertySourceBitDepth, &size, &depth) == noErr, depth != 0 else {
            return nil
        }
        return Int(abs(depth))
    }

    private static func khz(_ sr: Double) -> String {
        guard sr > 0 else { return "" }
        let k = sr / 1000
        return k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
    }

    private static func readMetadata(_ url: URL) async -> Meta {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        let asset = AVURLAsset(url: url)
        var title = fallbackTitle, artist = "", album = "", duration = 0.0
        var artwork: Data?
        // Best-effort: a non-audio temp file (tests) just yields the fallbacks.
        if let secs = try? await asset.load(.duration) { duration = CMTimeGetSeconds(secs) }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.value)
                switch key {
                case .commonKeyTitle:  if let s = value as? String { title = s }
                case .commonKeyArtist: if let s = value as? String { artist = s }
                case .commonKeyAlbumName: if let s = value as? String { album = s }
                case .commonKeyArtwork: if let d = value as? Data { artwork = d }
                default: break
                }
            }
        }
        if duration.isNaN { duration = 0 }
        return Meta(title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }
}
