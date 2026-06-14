import Foundation

/// Typed errors from Microsoft Graph calls; `.unauthorized` drives the forced-refresh+retry in OneDriveProvider.
enum GraphError: Error, LocalizedError {
    case unauthorized               // 401 — token expired / revoked mid-enumeration
    case http(Int)                  // any other non-200 status
    case badResponse                // couldn't decode the response body

    var errorDescription: String? {
        switch self {
        case .unauthorized:   return "Graph request unauthorized (401) — token refresh required"
        case .http(let s):    return "Graph HTTP error \(s)"
        case .badResponse:    return "Graph returned an unexpected response body"
        }
    }
}

/// A DriveItem from Graph. A folder has a non-nil `folder` facet; a file has a `file` facet (which
/// carries the mimeType). We only decode the fields we classify on.
struct GraphItem: Decodable, Equatable {
    var id: String; var name: String
    var folder: Folder?; var file: File?
    struct Folder: Decodable, Equatable { var childCount: Int? }
    struct File: Decodable, Equatable { var mimeType: String? }
}
struct GraphListPage: Equatable { var folders: [GraphItem]; var tracks: [GraphItem]; var nextLink: String? }

struct GraphAPIClient {
    let http: HTTPClient

    static func parseChildren(_ data: Data) throws -> GraphListPage {
        struct R: Decodable {
            var value: [GraphItem]?
            var nextLink: String?
            enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        let items = r.value ?? []
        let folders = items.filter { $0.folder != nil }
        let tracks = items.filter { item in
            // A folder is never a track; cloud uploads often have an opaque/absent mime, so fall
            // back to the filename extension.
            guard item.folder == nil else { return false }
            return AudioMime.isAudio(item.file?.mimeType ?? "") || AudioMime.isAudioByExtension(item.name)
        }
        return GraphListPage(folders: folders, tracks: tracks, nextLink: r.nextLink)
    }

    static func childrenRequest(parentId: String, accessToken: String) -> URLRequest {
        let base = "https://graph.microsoft.com/v1.0/me/drive"
        let path = parentId == "root"
            ? "\(base)/root/children"
            : "\(base)/items/\(parentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parentId)/children"
        var c = URLComponents(string: path)!
        c.queryItems = [.init(name: "$top", value: "1000"),
                        .init(name: "$select", value: "id,name,folder,file")]
        var req = URLRequest(url: c.url!); req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func nextRequest(nextLink: String, accessToken: String) -> URLRequest {
        var req = URLRequest(url: URL(string: nextLink)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Graph's /content endpoint streams the whole file and ignores Range, so we send no Range header
    /// (unlike Drive's alt=media, which honours byte ranges).
    static func contentRequest(fileId: String, accessToken: String) -> URLRequest {
        let id = fileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileId
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(id)/content")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// List all children of a folder, following `@odata.nextLink`.
    /// Throws `GraphError.unauthorized` on 401, `GraphError.http(_)` on other non-200 statuses.
    func listChildren(parentId: String, accessToken: String) async throws -> (folders: [GraphItem], tracks: [GraphItem]) {
        var folders: [GraphItem] = [], tracks: [GraphItem] = []
        var request: URLRequest? = Self.childrenRequest(parentId: parentId, accessToken: accessToken)
        while let req = request {
            let resp = try await http.send(req)
            guard resp.status == 200 else {
                throw resp.status == 401 ? GraphError.unauthorized : GraphError.http(resp.status)
            }
            let page = try Self.parseChildren(resp.data)
            folders += page.folders; tracks += page.tracks
            request = page.nextLink.map { Self.nextRequest(nextLink: $0, accessToken: accessToken) }
        }
        return (folders, tracks)
    }
}
