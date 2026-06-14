import XCTest
@testable import NanoMeters

final class GoogleDriveProviderTests: XCTestCase {
    func test_enumerate_buildsFolderTreeAndTrackDescriptors() async throws {
        // root "mine" → folder "house" + track "intro"; house → track "deep".
        let http = MockHTTPClient(responses: [
            .init(json: #"{"files":[{"id":"house","name":"House","mimeType":"application/vnd.google-apps.folder"},{"id":"intro","name":"Intro.mp3","mimeType":"audio/mpeg"}]}"#),
            .init(json: #"{"files":[{"id":"deep","name":"Deep.wav","mimeType":"audio/wav"}]}"#)])
        let provider = GoogleDriveProvider(api: DriveAPIClient(http: http), accessToken: { _ in "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "mine", rootName: "My Productions", rootId: "mine")
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Productions", "House"])
        let root = r.folders.first { $0.id == "mine" }!
        XCTAssertTrue(root.childFolderIds.contains("house"))
        XCTAssertEqual(root.trackIds, ["intro"])
        XCTAssertEqual(r.folders.first { $0.id == "house" }?.trackIds, ["deep"])
        XCTAssertEqual(Set(r.tracks.map(\.providerFileId)), ["intro", "deep"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark == nil })   // cloud → no bookmark
    }

    // MARK: - FIX C: 401 mid-enumeration → forced refresh + retry

    /// When listChildren returns 401, GoogleDriveProvider must force-refresh the token and retry
    /// that single folder's listing.  The enumerate result must be complete and successful.
    func test_enumerate_401_triggersForceRefreshAndRetry() async throws {
        // Two API calls for "mine":
        //   call 1 → 401 (triggers forced refresh)
        //   call 2 → valid response (with the fresh token)
        let http = MockHTTPClient(responses: [
            .init(status: 401, json: "{}"),
            .init(json: #"{"files":[{"id":"song","name":"Song.mp3","mimeType":"audio/mpeg"}]}"#)
        ])
        var accessCallForceFlags: [Bool] = []
        let provider = GoogleDriveProvider(
            api: DriveAPIClient(http: http),
            accessToken: { force in
                accessCallForceFlags.append(force)
                // Return a different token on force so we can verify force was passed.
                return force ? "AT2" : "AT"
            }
        )
        let r = try await provider.enumerate(
            rootBookmark: nil, providerFolderId: "mine", rootName: "My Drive", rootId: "mine")

        // Enumeration must succeed and return the track.
        XCTAssertEqual(r.tracks.count, 1, "should have enumerated one track after 401-retry")
        XCTAssertEqual(r.tracks.first?.providerFileId, "song")

        // accessToken must have been called at least twice: first with false, then with true (forced).
        XCTAssertTrue(accessCallForceFlags.contains(false), "initial access should be non-forced")
        XCTAssertTrue(accessCallForceFlags.contains(true),  "retry after 401 must request forced refresh")
    }

    /// Regression (FIX 1): a Drive graph where "a" lists "b" as a child and "b" lists "a" as a child
    /// is a cycle. `enumerate` must return (not hang) and each folder must appear exactly once.
    func test_enumerate_cyclicDrive_terminates() async throws {
        // The MockHTTPClient pops responses in order. We need it to keep returning responses even
        // when polled many times (cycle guard should terminate after 2 real API calls, but we give
        // a generous supply to make sure the test doesn't hang if the guard is slightly wider).
        //
        // Round-trip of responses:
        //   call 1 → list("a"): returns folder "b" as child
        //   call 2 → list("b"): returns folder "a" as child  ← cycle
        //   Any further calls → empty page (guard must have fired before this)
        let cycleResponseA = #"{"files":[{"id":"b","name":"B","mimeType":"application/vnd.google-apps.folder"}]}"#
        let cycleResponseB = #"{"files":[{"id":"a","name":"A","mimeType":"application/vnd.google-apps.folder"}]}"#
        let empty = #"{"files":[]}"#
        // 2 real calls + plenty of empty backstops so MockHTTPClient never runs dry.
        let stubs = [MockHTTPClient.Stub(json: cycleResponseA),
                     MockHTTPClient.Stub(json: cycleResponseB)] +
                    Array(repeating: MockHTTPClient.Stub(json: empty), count: 10)
        let http = MockHTTPClient(responses: stubs)
        let provider = GoogleDriveProvider(api: DriveAPIClient(http: http), accessToken: { _ in "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "a", rootName: "A", rootId: "a")
        // Each folder must appear exactly once — the cycle guard deduplicates.
        let ids = r.folders.map(\.id)
        XCTAssertEqual(ids.filter { $0 == "a" }.count, 1, "folder 'a' must appear exactly once")
        XCTAssertEqual(ids.filter { $0 == "b" }.count, 1, "folder 'b' must appear exactly once")
        XCTAssertEqual(Set(ids), ["a", "b"])
    }
}
