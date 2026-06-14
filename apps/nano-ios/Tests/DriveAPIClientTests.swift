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
    func test_listRequest_carriesParentQueryAndAuth() {
        let req = DriveAPIClient.listRequest(parentId: "root", pageToken: "PT", accessToken: "AT")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("'root'%20in%20parents") || url.contains("'root' in parents"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertTrue(url.contains("pageToken=PT"))
    }
    func test_mediaRequest_isAltMedia_withRange_andAuth() {
        let req = DriveAPIClient.mediaRequest(fileId: "a1", accessToken: "AT", offset: 0)
        XCTAssertTrue(req.url!.absoluteString.contains("/files/a1?alt=media"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-")
    }
}
