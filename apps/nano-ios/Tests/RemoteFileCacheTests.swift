import XCTest
@testable import NanoMeters

final class RemoteFileCacheTests: XCTestCase {
    func test_storeAndHit_returnsLocalURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        let cache = RemoteFileCache(directory: dir, maxBytes: 10_000)
        let url = try await cache.localURL(sourceId: "gdrive", fileId: "a1") { Data(repeating: 1, count: 100) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var called = false
        _ = try await cache.localURL(sourceId: "gdrive", fileId: "a1") { called = true; return Data() }
        XCTAssertFalse(called)   // second call is a cache hit, downloader not invoked
        try? FileManager.default.removeItem(at: dir)
    }
    func test_lru_evictsOldestOverBudget() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        let cache = RemoteFileCache(directory: dir, maxBytes: 250)
        _ = try await cache.localURL(sourceId: "s", fileId: "a") { Data(repeating: 1, count: 100) }
        _ = try await cache.localURL(sourceId: "s", fileId: "b") { Data(repeating: 1, count: 100) }
        _ = try await cache.localURL(sourceId: "s", fileId: "c") { Data(repeating: 1, count: 100) }  // 300 > 250 → evict "a"
        XCTAssertFalse(cache.isCached(sourceId: "s", fileId: "a"))
        XCTAssertTrue(cache.isCached(sourceId: "s", fileId: "c"))
        try? FileManager.default.removeItem(at: dir)
    }
}
