import Foundation

/// The "Playing from" label the engine carries so Now Playing / the queue can show where
/// playback started (handoff §03 "Playing from context"). Set at the moment a track is tapped.
struct PlayContext: Equatable {
    var kind: String   // e.g. "PLAYING FROM LIBRARY"
    var name: String   // e.g. "All Songs"

    static let library = PlayContext(kind: "PLAYING FROM LIBRARY", name: "All Songs")
    static let search  = PlayContext(kind: "PLAYING FROM SEARCH",  name: "Search")
    static func playlist(_ name: String) -> PlayContext {
        PlayContext(kind: "PLAYING FROM PLAYLIST", name: name)
    }
}
