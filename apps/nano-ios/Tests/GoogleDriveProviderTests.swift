import XCTest
@testable import NanoMeters

final class GoogleDriveProviderTests: XCTestCase {
    func test_enumerate_buildsFolderTreeAndTrackDescriptors() async throws {
        // root "mine" → folder "house" + track "intro"; house → track "deep".
        let http = MockHTTPClient(responses: [
            .init(json: #"{"files":[{"id":"house","name":"House","mimeType":"application/vnd.google-apps.folder"},{"id":"intro","name":"Intro.mp3","mimeType":"audio/mpeg"}]}"#),
            .init(json: #"{"files":[{"id":"deep","name":"Deep.wav","mimeType":"audio/wav"}]}"#)])
        let provider = GoogleDriveProvider(api: DriveAPIClient(http: http), accessToken: { "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "mine", rootName: "My Productions", rootId: "mine")
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Productions", "House"])
        let root = r.folders.first { $0.id == "mine" }!
        XCTAssertTrue(root.childFolderIds.contains("house"))
        XCTAssertEqual(root.trackIds, ["intro"])
        XCTAssertEqual(r.folders.first { $0.id == "house" }?.trackIds, ["deep"])
        XCTAssertEqual(Set(r.tracks.map(\.providerFileId)), ["intro", "deep"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark == nil })   // cloud → no bookmark
    }
}
