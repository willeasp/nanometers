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
        // Enumerated local tracks carry NO per-file bookmark (FIX 2 — folder-bookmark path instead).
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark == nil })
    }

    // MARK: - FIX 1: Deterministic ids

    func test_enumerate_idsAreDeterministicAcrossCalls() throws {
        let root = try tempTree()
        let r1 = try DirectoryEnumerator.enumerate(folderURL: root, rootId: "ROOT", rootName: "My Music")
        let r2 = try DirectoryEnumerator.enumerate(folderURL: root, rootId: "ROOT", rootName: "My Music")

        // Folder ids must be identical across both calls.
        let ids1 = Set(r1.folders.map(\.id))
        let ids2 = Set(r2.folders.map(\.id))
        XCTAssertEqual(ids1, ids2, "Folder ids must be stable across process calls (no hashValue randomness)")

        // Track ids must also be identical.
        let tids1 = Set(r1.tracks.map(\.id))
        let tids2 = Set(r2.tracks.map(\.id))
        XCTAssertEqual(tids1, tids2, "Track ids must be stable across process calls")

        // providerFileId is the path relative to root (e.g. "House/track1.wav", "intro.mp3").
        let relPaths = Set(r1.tracks.compactMap(\.providerFileId))
        XCTAssertTrue(relPaths.contains("intro.mp3"),
                      "Root-level track should have relative providerFileId 'intro.mp3', got: \(relPaths)")
        XCTAssertTrue(relPaths.contains("House/track1.wav"),
                      "Nested track should have relative providerFileId 'House/track1.wav', got: \(relPaths)")
    }

    func test_stableId_isConsistent() {
        // The same string always produces the same id, and different strings differ.
        let a = DirectoryEnumerator.stableId("House/track1.wav")
        let b = DirectoryEnumerator.stableId("House/track1.wav")
        let c = DirectoryEnumerator.stableId("House/track2.wav")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.hasPrefix("local:"), "stableId must carry 'local:' namespace prefix")
    }

    // MARK: - FIX 4: Symlink / cycle guard

    func test_enumerate_symlinkCycle_terminates() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("symlink-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        // Try to create a symlink cycle: root/link → root. On most simulator sandboxes this is
        // allowed; if createSymbolicLink throws we skip gracefully instead of failing.
        let linkURL = root.appendingPathComponent("link")
        do {
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: root)
        } catch {
            // Sandbox may disallow symlink creation — skip.
            return
        }

        // Must return without hanging (symlink guard skips the link entry).
        let r = try DirectoryEnumerator.enumerate(folderURL: root, rootId: "ROOT", rootName: "Root")
        // The symlink should NOT appear as a child folder.
        XCTAssertFalse(r.folders.contains { $0.name == "link" },
                       "Symlink should be skipped by the FIX 4 guard")
    }
}
