import Foundation

struct HTTPResponse { var status: Int; var data: Data }

protocol HTTPClient { func send(_ req: URLRequest) async throws -> HTTPResponse }

struct URLSessionHTTPClient: HTTPClient {
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await URLSession.shared.data(for: req)
        return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}
