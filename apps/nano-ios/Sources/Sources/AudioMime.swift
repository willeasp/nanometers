import Foundation

/// Shared audio-file classification used by every cloud provider (Drive, OneDrive, …). Cloud APIs
/// often report uploaded audio as an opaque mime (octet-stream), so we also fall back to the extension.
enum AudioMime {
    static func isAudio(_ m: String) -> Bool { m.hasPrefix("audio/") }
    private static let audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aif","aiff","flac","alac","ogg","caf"]
    static func isAudioByExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }
}
