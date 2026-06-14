import XCTest
@testable import NanoMeters

final class DriveAPIClientTests: XCTestCase {
    func test_parseList_splitsFoldersAndAudio_withNextPageToken() throws {
        let json = #"""
        {"nextPageToken":"NPT","files":[
          {"id":"f1","name":"House","mimeType":"application/vnd.google-apps.folder"},
          {"id":"a1","name":"Caldera.mp3","mimeType":"audio/mpeg"},
          {"id":"x1","name":"notes.txt","mimeType":"text/plain"}]}
        """#
        let page = try DriveAPIClient.parseList(Data(json.utf8))
        XCTAssertEqual(page.nextPageToken, "NPT")
        XCTAssertEqual(page.folders.map(\.id), ["f1"])
        XCTAssertEqual(page.tracks.map(\.id), ["a1"])      // audio/* only; text filtered
        XCTAssertEqual(page.tracks.first?.name, "Caldera.mp3")
    }

    /// Regression (FIX 2): Drive often uploads audio as application/octet-stream. The file should
    /// be classified as a track based on its extension when the mimeType is opaque.
    func test_parseList_classifiesOctetStreamAudioByExtension() throws {
        let json = #"""
        {"files":[
          {"id":"x","name":"Track.flac","mimeType":"application/octet-stream"},
          {"id":"y","name":"doc","mimeType":"application/vnd.google-apps.document"},
          {"id":"z","name":"Song.aiff","mimeType":"application/octet-stream"}
        ]}
        """#
        let page = try DriveAPIClient.parseList(Data(json.utf8))
        // Both .flac and .aiff must be classified as tracks.
        XCTAssertEqual(Set(page.tracks.map(\.id)), ["x", "z"],
                       "octet-stream files with audio extensions must be classified as tracks")
        // Google-native doc must be dropped.
        XCTAssertFalse(page.tracks.contains { $0.id == "y" }, "google-apps types must be dropped")
        XCTAssertFalse(page.folders.contains { $0.id == "y" }, "google-apps doc is not a folder either")
    }

    func test_listRequest_carriesParentQueryAndAuth() {
        let req = DriveAPIClient.listRequest(parentId: "root", pageToken: "PT", accessToken: "AT")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("'root'%20in%20parents") || url.contains("'root' in parents"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertTrue(url.contains("pageToken=PT"))
    }

    /// Regression (FIX 3): a parentId containing a single-quote must be escaped so the Drive query
    /// is syntactically valid and does not allow injection.
    func test_listRequest_escapesSingleQuoteInParentId() {
        let req = DriveAPIClient.listRequest(parentId: "it's-a-folder", pageToken: nil, accessToken: "AT")
        let raw = req.url!.absoluteString
        // The percent-encoded form of \' in the q= value is %5C%27; alternatively the raw form
        // "it\\'s-a-folder" must appear somewhere in the query. Either encoding is correct.
        let decoded = raw.removingPercentEncoding ?? raw
        XCTAssertTrue(decoded.contains("\\'"), "single-quote in parentId must be escaped as \\' in the q param")
    }

    func test_mediaRequest_isAltMedia_withRange_andAuth() {
        let req = DriveAPIClient.mediaRequest(fileId: "a1", accessToken: "AT", offset: 0)
        XCTAssertTrue(req.url!.absoluteString.contains("/files/a1?alt=media"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-")
    }
}
