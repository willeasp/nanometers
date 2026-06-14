import XCTest
@testable import NanoMeters

final class OneDriveProviderTests: XCTestCase {
    func test_enumerate_buildsFolderTreeAndTrackDescriptors() async throws {
        // root → folder "house" + track "intro"; house → track "deep".
        let http = MockHTTPClient(responses: [
            .init(json: #"{"value":[{"id":"house","name":"House","folder":{}},{"id":"intro","name":"Intro.mp3","file":{"mimeType":"audio/mpeg"}}]}"#),
            .init(json: #"{"value":[{"id":"deep","name":"Deep.wav","file":{"mimeType":"audio/wav"}}]}"#)])
        let provider = OneDriveProvider(api: GraphAPIClient(http: http), accessToken: { _ in "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "root", rootName: "My Productions", rootId: "root")
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Productions", "House"])
        let root = r.folders.first { $0.id == "root" }!
        XCTAssertTrue(root.childFolderIds.contains("house"))
        XCTAssertEqual(root.trackIds, ["intro"])
        XCTAssertEqual(r.folders.first { $0.id == "house" }?.trackIds, ["deep"])
        XCTAssertEqual(Set(r.tracks.map(\.providerFileId)), ["intro", "deep"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark == nil })   // cloud → no bookmark
        // format from extension, title without it.
        XCTAssertEqual(r.tracks.first { $0.id == "intro" }?.format, "MP3")
        XCTAssertEqual(r.tracks.first { $0.id == "intro" }?.title, "Intro")
    }

    /// 401 mid-enumeration → forced refresh + retry that single folder's listing.
    func test_enumerate_401_triggersForceRefreshAndRetry() async throws {
        let http = MockHTTPClient(responses: [
            .init(status: 401, json: "{}"),
            .init(json: #"{"value":[{"id":"song","name":"Song.mp3","file":{"mimeType":"audio/mpeg"}}]}"#)
        ])
        var accessCallForceFlags: [Bool] = []
        let provider = OneDriveProvider(
            api: GraphAPIClient(http: http),
            accessToken: { force in
                accessCallForceFlags.append(force)
                return force ? "AT2" : "AT"
            }
        )
        let r = try await provider.enumerate(
            rootBookmark: nil, providerFolderId: "root", rootName: "OneDrive", rootId: "root")

        XCTAssertEqual(r.tracks.count, 1, "should have enumerated one track after 401-retry")
        XCTAssertEqual(r.tracks.first?.providerFileId, "song")
        XCTAssertTrue(accessCallForceFlags.contains(false), "initial access should be non-forced")
        XCTAssertTrue(accessCallForceFlags.contains(true),  "retry after 401 must request forced refresh")
    }

    /// A graph where "a" lists "b" and "b" lists "a" is a cycle. `enumerate` must return (not hang)
    /// and each folder must appear exactly once.
    func test_enumerate_cyclicTree_terminates() async throws {
        let cycleA = #"{"value":[{"id":"b","name":"B","folder":{}}]}"#
        let cycleB = #"{"value":[{"id":"a","name":"A","folder":{}}]}"#
        let empty = #"{"value":[]}"#
        let stubs = [MockHTTPClient.Stub(json: cycleA),
                     MockHTTPClient.Stub(json: cycleB)] +
                    Array(repeating: MockHTTPClient.Stub(json: empty), count: 10)
        let http = MockHTTPClient(responses: stubs)
        let provider = OneDriveProvider(api: GraphAPIClient(http: http), accessToken: { _ in "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "a", rootName: "A", rootId: "a")
        let ids = r.folders.map(\.id)
        XCTAssertEqual(ids.filter { $0 == "a" }.count, 1, "folder 'a' must appear exactly once")
        XCTAssertEqual(ids.filter { $0 == "b" }.count, 1, "folder 'b' must appear exactly once")
        XCTAssertEqual(Set(ids), ["a", "b"])
    }
}
