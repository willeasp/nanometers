import XCTest
@testable import NanoMeters

@MainActor
final class DirectoryEnumeratorTests: XCTestCase {
    private func tempTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("enum-\(UUID())")
        let house = root.appendingPathComponent("House")
        try fm.createDirectory(at: house, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: root.appendingPathComponent("intro.mp3"))
        try Data([1,2,3]).write(to: house.appendingPathComponent("track1.wav"))
        try Data([1,2,3]).write(to: house.appendingPathComponent("notes.txt"))   // non-audio, ignored
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    func test_enumerate_buildsTreeAndFiltersAudio() throws {
        let root = try tempTree()
        let r = try DirectoryEnumerator.enumerate(folderURL: root, rootId: "ROOT", rootName: "My Music")
        // Root folder + House folder.
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Music", "House"])
        let rootF = r.folders.first { $0.id == "ROOT" }!
        XCTAssertEqual(rootF.trackIds.count, 1)                       // intro.mp3 only
        let houseF = r.folders.first { $0.name == "House" }!
        XCTAssertEqual(houseF.parentId, "ROOT")
        XCTAssertEqual(houseF.trackIds.count, 1)                      // track1.wav (notes.txt filtered)
        XCTAssertTrue(rootF.childFolderIds.contains(houseF.id))
        // Track descriptors: titles fall back to filename; formats upper-cased ext.
        XCTAssertEqual(Set(r.tracks.map(\.title)), ["intro", "track1"])
        XCTAssertEqual(Set(r.tracks.map(\.format)), ["MP3", "WAV"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark != nil })     // per-file bookmark captured
    }
}
