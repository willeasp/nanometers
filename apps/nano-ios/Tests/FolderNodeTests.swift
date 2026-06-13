import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class FolderNodeTests: XCTestCase {
    func test_folderNode_byId_andChildren() throws {
        let ctx = try TestDB.context()
        ctx.insert(FolderNode(id: "root", sourceId: "gdrive", name: "My Productions",
                              parentId: nil, childFolderIds: ["house", "dnb"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "root"))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "root"))
        let root = try LibraryStore.folderNode(id: "root", ctx)
        XCTAssertEqual(root?.childFolderIds, ["house", "dnb"])
        let children = try LibraryStore.childFolders(of: "root", ctx)
        XCTAssertEqual(Set(children.map(\.name)), ["House", "Drum & Bass"])
    }

    func test_tracksInFolder_resolvesIdsInOrder_skippingDangling() throws {
        let ctx = try TestDB.context()
        let t1 = Track(title: "One", artist: "", album: "")
        let t2 = Track(title: "Two", artist: "", album: "")
        [t1, t2].forEach(ctx.insert)
        ctx.insert(FolderNode(id: "f", sourceId: "local", name: "F",
                              trackIds: [t2.id, UUID(), t1.id]))   // middle id is dangling
        let tracks = try LibraryStore.tracksInFolder(id: "f", ctx)
        XCTAssertEqual(tracks.map(\.title), ["Two", "One"])
    }
}
