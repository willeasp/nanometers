import Foundation

enum DriveAudioMime { static func isAudio(_ m: String) -> Bool { m.hasPrefix("audio/") } }
struct DriveFile: Decodable, Equatable { var id: String; var name: String; var mimeType: String }
struct DriveListPage: Equatable { var folders: [DriveFile]; var tracks: [DriveFile]; var nextPageToken: String? }

struct DriveAPIClient {
    let http: HTTPClient
    static let folderMime = "application/vnd.google-apps.folder"
    static func parseList(_ data: Data) throws -> DriveListPage {
        struct R: Decodable { var nextPageToken: String?; var files: [DriveFile]? }
        let r = try JSONDecoder().decode(R.self, from: data)
        let files = r.files ?? []
        return DriveListPage(folders: files.filter { $0.mimeType == folderMime },
                             tracks: files.filter { DriveAudioMime.isAudio($0.mimeType) },
                             nextPageToken: r.nextPageToken)
    }
    static func listRequest(parentId: String, pageToken: String?, accessToken: String) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: "'\(parentId)' in parents and trashed=false"),
                        .init(name: "fields", value: "nextPageToken,files(id,name,mimeType)"),
                        .init(name: "pageSize", value: "1000")]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        var req = URLRequest(url: c.url!); req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }
    static func mediaRequest(fileId: String, accessToken: String, offset: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        return req
    }
    /// List all children of a folder, following nextPageToken.
    func listChildren(parentId: String, accessToken: String) async throws -> (folders: [DriveFile], tracks: [DriveFile]) {
        var folders: [DriveFile] = [], tracks: [DriveFile] = [], token: String? = nil
        repeat {
            let resp = try await http.send(Self.listRequest(parentId: parentId, pageToken: token, accessToken: accessToken))
            guard resp.status == 200 else { throw NSError(domain: "Drive", code: resp.status) }
            let page = try Self.parseList(resp.data)
            folders += page.folders; tracks += page.tracks; token = page.nextPageToken
        } while token != nil
        return (folders, tracks)
    }
}
