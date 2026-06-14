import XCTest
@testable import NanoMeters

@MainActor
final class RemotePlaybackPrepTests: XCTestCase {

    // Cloud track: providerFileId set, no bundledName, no bookmark, no folderBookmark → needs prep.
    func test_needsRemotePrep_trueForCloudTrack() {
        let cloud = Track(title: "x", artist: "", album: "")
        cloud.providerFileId = "a1"
        cloud.sourceId = "gdrive"
        XCTAssertTrue(AudioEngine.needsRemotePrep(cloud))
    }

    // Enumerated LOCAL track: folderBookmark set + providerFileId (relative path) → local, no prep.
    func test_needsRemotePrep_falseForEnumeratedLocalTrack() {
        let local = Track(title: "y", artist: "", album: "",
                          folderBookmark: Data([0xAB, 0xCD]))
        local.providerFileId = "House/Caldera.wav"
        XCTAssertFalse(AudioEngine.needsRemotePrep(local))
    }

    // Bundled track → no prep.
    func test_needsRemotePrep_falseForBundledTrack() {
        let bundled = Track(title: "z", artist: "", album: "", bundledName: "biljam.mp3")
        XCTAssertFalse(AudioEngine.needsRemotePrep(bundled))
    }

    // Direct-bookmark track (no providerFileId) → no prep.
    func test_needsRemotePrep_falseForDirectBookmarkTrack() {
        let bm = Track(title: "w", artist: "", album: "", bookmark: Data([0x01]))
        XCTAssertFalse(AudioEngine.needsRemotePrep(bm))
    }

    // A track with no providerFileId at all is just an unresolvable local → no prep.
    func test_needsRemotePrep_falseForTrackWithNoProviderFileId() {
        let t = Track(title: "unresolvable", artist: "", album: "")
        XCTAssertFalse(AudioEngine.needsRemotePrep(t))
    }
}
