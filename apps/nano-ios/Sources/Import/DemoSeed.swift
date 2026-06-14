import Foundation
import SwiftData
import AVFoundation

/// First-run content: two real, playable sample tracks that ship in the app bundle
/// (`Resources/biljam.mp3`, `Resources/Mercy.mp3`). Neither has embedded artwork, so they also
/// exercise the fallback art tile. Imported files (handoff §04) add more on top of these.
enum DemoSeed {
    @MainActor
    static func seedIfEmpty(_ ctx: ModelContext) {
        guard (try? LibraryStore.allTracks(ctx).isEmpty) ?? false else { return }
        let demos: [Track] = [
            demoTrack(title: "Biljam", durationSec: 70, file: "biljam.mp3"),
            demoTrack(title: "Mercy", durationSec: 220, file: "Mercy.mp3"),
        ]
        demos.forEach(ctx.insert)
    }

    private static func demoTrack(title: String, durationSec: Double, file: String) -> Track {
        let fmt = bundledFormat(file)
        return Track(title: title, artist: "you", album: "Demos",
                     displayPath: SourceKind.local.label, durationSec: durationSec,
                     format: fmt.format, sampleRate: fmt.rate, bitDepth: fmt.bits,
                     hasEmbeddedArt: false, bundledName: file)
    }

    /// Real container format + sample rate (kHz) + bit depth for a bundled file, read from the decoder
    /// — so the demo title line shows the truth ("MP3 · 44.1 kHz"), not the old bogus bitrate string.
    private static func bundledFormat(_ name: String) -> (format: String, rate: String, bits: Int?) {
        let ext = (name as NSString).pathExtension.uppercased()
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let af = try? AVAudioFile(forReading: url) else { return (ext, "", nil) }
        let asbd = af.fileFormat.streamDescription.pointee
        let sr = asbd.mSampleRate
        let rate: String
        if sr > 0 {
            let k = sr / 1000
            rate = k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
        } else { rate = "" }
        let bits = Int(asbd.mBitsPerChannel)        // 0 for lossy MP3 → nil
        return (ext, rate, bits > 0 ? bits : nil)
    }
}
