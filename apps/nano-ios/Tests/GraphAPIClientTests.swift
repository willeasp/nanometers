import XCTest
@testable import NanoMeters

final class GraphAPIClientTests: XCTestCase {
    func test_parseChildren_classifiesItemsAndReadsNextLink() throws {
        // A folder, an audio/mpeg file, a dropped PDF, and an octet-stream named song.flac (kept by ext).
        let json = #"""
        {"value":[
          {"id":"f1","name":"House","folder":{"childCount":3}},
          {"id":"a1","name":"Caldera.mp3","file":{"mimeType":"audio/mpeg"}},
          {"id":"d1","name":"notes.pdf","file":{"mimeType":"application/pdf"}},
          {"id":"x1","name":"song.flac","file":{"mimeType":"application/octet-stream"}}
        ],"@odata.nextLink":"https://graph.microsoft.com/v1.0/next?page=2"}
        """#
        let page = try GraphAPIClient.parseChildren(Data(json.utf8))
        XCTAssertEqual(page.folders.map(\.id), ["f1"])
        XCTAssertEqual(Set(page.tracks.map(\.id)), ["a1", "x1"])     // mp3 by mime, flac by extension
        XCTAssertFalse(page.tracks.contains { $0.id == "d1" }, "pdf must be dropped")
        XCTAssertEqual(page.nextLink, "https://graph.microsoft.com/v1.0/next?page=2")
    }

    func test_parseChildren_noNextLink() throws {
        let json = #"{"value":[{"id":"a","name":"A.wav","file":{"mimeType":"audio/wav"}}]}"#
        let page = try GraphAPIClient.parseChildren(Data(json.utf8))
        XCTAssertNil(page.nextLink)
        XCTAssertEqual(page.tracks.map(\.id), ["a"])
    }

    func test_childrenRequest_root_hitsDriveRoot_withAuth() {
        let req = GraphAPIClient.childrenRequest(parentId: "root", accessToken: "AT")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("/me/drive/root/children"), "root must hit /me/drive/root/children; got \(url)")
        XCTAssertTrue(url.contains("$top=1000"))
        XCTAssertTrue(url.contains("id,name,folder,file"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
    }

    func test_childrenRequest_id_hitsItemChildren_withAuth() {
        let req = GraphAPIClient.childrenRequest(parentId: "ABC123", accessToken: "AT")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("/me/drive/items/ABC123/children"), "id must hit /me/drive/items/<id>/children; got \(url)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
    }

    func test_contentRequest_noRangeHeader_hitsContent() {
        let req = GraphAPIClient.contentRequest(fileId: "a1", accessToken: "AT")
        XCTAssertTrue(req.url!.absoluteString.contains("/me/drive/items/a1/content"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertNil(req.value(forHTTPHeaderField: "Range"), "Graph /content ignores Range — we must not send one")
    }

    func test_listChildren_followsNextLink_thenStops() async throws {
        let http = MockHTTPClient(responses: [
            .init(json: #"{"value":[{"id":"a","name":"A.mp3","file":{"mimeType":"audio/mpeg"}}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/next"}"#),
            .init(json: #"{"value":[{"id":"b","name":"B.wav","file":{"mimeType":"audio/wav"}}]}"#)
        ])
        let (folders, tracks) = try await GraphAPIClient(http: http).listChildren(parentId: "root", accessToken: "AT")
        XCTAssertTrue(folders.isEmpty)
        XCTAssertEqual(tracks.map(\.id), ["a", "b"], "must page through nextLink and concatenate")
    }

    func test_listChildren_401_throwsUnauthorized() async throws {
        let http = MockHTTPClient(responses: [.init(status: 401, json: "{}")])
        do {
            _ = try await GraphAPIClient(http: http).listChildren(parentId: "root", accessToken: "AT")
            XCTFail("expected GraphError.unauthorized")
        } catch GraphError.unauthorized {
            // expected
        }
    }
}
