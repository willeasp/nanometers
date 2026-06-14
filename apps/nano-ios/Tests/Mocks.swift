import Foundation
@testable import NanoMeters

/// Shared test doubles for OAuthClientTests, DriveAPIClientTests, GoogleDriveProviderTests, etc.
///
/// Thread-safety note: MockHTTPClient is a class used from async contexts in tests. Swift's structured
/// concurrency does not guarantee actor isolation for plain classes — tests that need concurrency-safe
/// call counting should use `CountingHTTPClient` below instead.
final class MockHTTPClient: HTTPClient {
    struct Stub { var status = 200; var json: String }
    private var responses: [Stub]
    private(set) var lastBody: String?
    /// All request bodies in order of arrival (useful for asserting revoke POSTs etc.).
    private(set) var recordedBodies: [String] = []
    /// Number of `send` calls made.
    private(set) var callCount: Int = 0
    init(responses: [Stub]) { self.responses = responses }
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        lastBody = body
        if let body { recordedBodies.append(body) }
        callCount += 1
        let s = responses.isEmpty ? Stub(json: "{}") : responses.removeFirst()
        return HTTPResponse(status: s.status, data: Data(s.json.utf8))
    }
}

/// Thread-safe HTTP client mock backed by a Swift actor — use this in concurrency tests where
/// multiple Tasks call `send` simultaneously (FIX A concurrent-coalescing test).
actor CountingHTTPClient {
    struct Stub { var status = 200; var json: String }
    private var responses: [Stub]
    private(set) var callCount: Int = 0
    init(responses: [Stub]) { self.responses = responses }
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        callCount += 1
        let s = responses.isEmpty ? Stub(json: "{}") : responses.removeFirst()
        return HTTPResponse(status: s.status, data: Data(s.json.utf8))
    }
}

/// Bridges a `CountingHTTPClient` actor into the `HTTPClient` protocol so it can be passed to
/// `OAuthClient`. Calls cross the actor boundary via `await`.
struct ActorBridgeHTTPClient: HTTPClient {
    let actor: CountingHTTPClient
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        try await actor.send(req)
    }
}
