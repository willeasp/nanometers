import Foundation

/// Typed errors from Drive API calls; `.unauthorized` drives the forced-refresh+retry in GoogleDriveProvider.
enum DriveError: Error, LocalizedError {
    case unauthorized               // 401 — token expired / revoked mid-enumeration
    case http(Int)                  // any other non-200 status
    case badResponse                // couldn't decode the response body

    var errorDescription: String? {
        switch self {
        case .unauthorized:   return "Drive request unauthorized (401) — token refresh required"
        case .http(let s):    return "Drive HTTP error \(s)"
        case .badResponse:    return "Drive returned an unexpected response body"
        }
    }
}

enum DriveAudioMime {
    static func isAudio(_ m: String) -> Bool { m.hasPrefix("audio/") }
    private static let audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aif","aiff","flac","alac","ogg","caf"]
    static func isAudioByExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }
}
struct DriveFile: Decodable, Equatable { var id: String; var name: String; var mimeType: String }
struct DriveListPage: Equatable { var folders: [DriveFile]; var tracks: [DriveFile]; var nextPageToken: String? }

struct DriveAPIClient {
    let http: HTTPClient
    static let folderMime = "application/vnd.google-apps.folder"
    static func parseList(_ data: Data) throws -> DriveListPage {
        struct R: Decodable { var nextPageToken: String?; var files: [DriveFile]? }
        let r = try JSONDecoder().decode(R.self, from: data)
        let files = r.files ?? []
        let folders = files.filter { $0.mimeType == folderMime }
        let tracks = files.filter { f in
            // Drop folder type and all Google-native doc types.
            guard f.mimeType != folderMime, !f.mimeType.hasPrefix("application/vnd.google-apps.") else { return false }
            // Accept if the mimeType is audio/* OR the filename carries a known audio extension
            // (Drive often reports uploaded audio files as application/octet-stream).
            return DriveAudioMime.isAudio(f.mimeType) || DriveAudioMime.isAudioByExtension(f.name)
        }
        return DriveListPage(folders: folders, tracks: tracks, nextPageToken: r.nextPageToken)
    }
    static func listRequest(parentId: String, pageToken: String?, accessToken: String) -> URLRequest {
        let p = parentId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: "'\(p)' in parents and trashed=false"),
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
    /// Throws `DriveError.unauthorized` on 401, `DriveError.http(_)` on other non-200 statuses.
    func listChildren(parentId: String, accessToken: String) async throws -> (folders: [DriveFile], tracks: [DriveFile]) {
        var folders: [DriveFile] = [], tracks: [DriveFile] = [], token: String? = nil
        repeat {
            let resp = try await http.send(Self.listRequest(parentId: parentId, pageToken: token, accessToken: accessToken))
            guard resp.status == 200 else {
                throw resp.status == 401 ? DriveError.unauthorized : DriveError.http(resp.status)
            }
            let page = try Self.parseList(resp.data)
            folders += page.folders; tracks += page.tracks; token = page.nextPageToken
        } while token != nil
        return (folders, tracks)
    }
}
