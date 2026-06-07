import Foundation
import SwiftData

/// First-run content so the shell isn't empty (handoff README — demo tracks; two are art-less to
/// show the fallback tile). Metadata-only: these aren't playable, which is fine — playback is Phase 2.
enum DemoSeed {
    @MainActor
    static func seedIfEmpty(_ ctx: ModelContext) {
        guard (try? LibraryStore.allTracks(ctx).isEmpty) ?? false else { return }
        let demos: [Track] = [
            Track(title: "Midnight Drive", artist: "Aurora Field", album: "Neon Atlas",
                  displayPath: SourceKind.local.label, durationSec: 214, format: "FLAC",
                  sampleRate: "24/96", hasEmbeddedArt: true),
            Track(title: "Glass Harbor", artist: "Aurora Field", album: "Neon Atlas",
                  displayPath: SourceKind.local.label, durationSec: 188, format: "FLAC",
                  sampleRate: "24/96", hasEmbeddedArt: true),
            Track(title: "Untitled Bounce", artist: "you", album: "Sketches",
                  displayPath: SourceKind.local.label, durationSec: 92, format: "WAV",
                  sampleRate: "24/48", hasEmbeddedArt: false),   // art-less → fallback tile
            Track(title: "Voice Memo 03", artist: "you", album: "Sketches",
                  displayPath: SourceKind.local.label, durationSec: 47, format: "M4A",
                  sampleRate: "16/44.1", hasEmbeddedArt: false), // art-less → fallback tile
        ]
        demos.forEach(ctx.insert)
    }
}
