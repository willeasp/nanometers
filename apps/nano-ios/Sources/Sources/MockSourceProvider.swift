import Foundation

#if DEBUG
/// A purely in-memory `SourceProvider` for headless UI testing. Conforms to `SourceProvider`, returns a
/// fixed 2-level Drive-shaped tree without any network or OAuth. The tree is shared between the app's
/// debug launch hook and the XCUITest so both see the same node IDs.
///
/// Tree:
///   Mock Drive (mock-root)
///   ├── House (mock-folder-house)
///   │   ├── Mock Caldera  (mock-track-caldera)
///   │   └── Mock Strata   (mock-track-strata)
///   └── DnB (mock-folder-dnb)
///       └── Mock Abyss    (mock-track-abyss)
struct MockSourceProvider: SourceProvider {
    var kind: SourceKind { .gdrive }

    // MARK: - Fixed IDs (stable strings so tests and the hook reference the same rows)

    static let rootId          = "mock-root"
    static let rootName        = "Mock Drive"
    static let houseId         = "mock-folder-house"
    static let dnbId           = "mock-folder-dnb"
    static let calderaId       = "mock-track-caldera"
    static let strataId        = "mock-track-strata"
    static let abyssId         = "mock-track-abyss"

    // MARK: - EnumerationResult (pre-built, re-used by the launch hook and tests)

    static var fixedResult: EnumerationResult {
        let folders = [
            FolderDescriptor(id: rootId, name: rootName, parentId: nil,
                             childFolderIds: [houseId, dnbId], trackIds: []),
            FolderDescriptor(id: houseId, name: "House", parentId: rootId,
                             childFolderIds: [], trackIds: [calderaId, strataId]),
            FolderDescriptor(id: dnbId, name: "DnB", parentId: rootId,
                             childFolderIds: [], trackIds: [abyssId]),
        ]
        let tracks = [
            TrackDescriptor(id: calderaId, title: "Mock Caldera", artist: "Mock Artist", album: "",
                            durationSec: 180, format: "MP3", bookmark: nil, providerFileId: calderaId),
            TrackDescriptor(id: strataId, title: "Mock Strata", artist: "Mock Artist", album: "",
                            durationSec: 240, format: "WAV", bookmark: nil, providerFileId: strataId),
            TrackDescriptor(id: abyssId, title: "Mock Abyss", artist: "Mock Artist", album: "",
                            durationSec: 200, format: "MP3", bookmark: nil, providerFileId: abyssId),
        ]
        return EnumerationResult(folders: folders, tracks: tracks)
    }

    // MARK: - SourceProvider

    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult {
        Self.fixedResult
    }
}
#endif
