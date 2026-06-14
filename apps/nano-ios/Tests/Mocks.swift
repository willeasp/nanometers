import Foundation
@testable import NanoMeters

/// Shared test doubles for OAuthClientTests, DriveAPIClientTests, GoogleDriveProviderTests, etc.
final class MockHTTPClient: HTTPClient {
    struct Stub { var status = 200; var json: String }
    private var responses: [Stub]
    private(set) var lastBody: String?
    init(responses: [Stub]) { self.responses = responses }
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        lastBody = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let s = responses.isEmpty ? Stub(json: "{}") : responses.removeFirst()
        return HTTPResponse(status: s.status, data: Data(s.json.utf8))
    }
}
