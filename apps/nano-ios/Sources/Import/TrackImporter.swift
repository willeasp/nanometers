import Foundation
import SwiftData
import AVFoundation
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
            // Kick analysis so the waveform/LUFS are ready by the time the row appears.
            Task { @MainActor in await WaveformStore.shared.bins(for: track) }
            count += 1
        }
        return count
    }

    private struct Meta { var title: String; var artist: String; var album: String; var duration: Double; var artwork: Data? }

    /// Real sample rate (as a kHz string, e.g. "96" / "44.1") + PCM bit depth from the decoder.
    /// Best-effort: a non-audio file (tests) yields ("", nil); lossy files report 0 bits → nil.
    private static func audioFormat(_ url: URL) -> (rate: String, bits: Int?) {
        guard let af = try? AVAudioFile(forReading: url) else { return ("", nil) }
        let asbd = af.fileFormat.streamDescription.pointee
        let bits = Int(asbd.mBitsPerChannel)
        return (khz(asbd.mSampleRate), bits > 0 ? bits : nil)
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
