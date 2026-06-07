import Foundation
import SwiftData

/// First-run content: two real, playable sample tracks that ship in the app bundle
/// (`Resources/biljam.mp3`, `Resources/Mercy.mp3`). Neither has embedded artwork, so they also
/// exercise the fallback art tile. Imported files (handoff §04) add more on top of these.
enum DemoSeed {
    @MainActor
    static func seedIfEmpty(_ ctx: ModelContext) {
        guard (try? LibraryStore.allTracks(ctx).isEmpty) ?? false else { return }
        let demos: [Track] = [
            Track(title: "Biljam", artist: "you", album: "Demos",
                  displayPath: SourceKind.local.label, durationSec: 70, format: "MP3",
                  sampleRate: "320", hasEmbeddedArt: false, bundledName: "biljam.mp3"),
            Track(title: "Mercy", artist: "you", album: "Demos",
                  displayPath: SourceKind.local.label, durationSec: 220, format: "MP3",
                  sampleRate: "320", hasEmbeddedArt: false, bundledName: "Mercy.mp3"),
        ]
        demos.forEach(ctx.insert)
    }
}
