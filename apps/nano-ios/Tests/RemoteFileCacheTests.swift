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

    /// Regression (FIX 4a): two concurrent `localURL` calls for the same (sourceId, fileId) must
    /// collapse to a SINGLE downloader invocation. Both callers get the same URL.
    func test_concurrentDownloads_sameFile_downloadOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RemoteFileCache(directory: dir, maxBytes: 10_000)

        // Counter actor: thread-safe invocation count visible from async context.
        actor Counter { var n = 0; func increment() { n += 1 } }
        let counter = Counter()

        // Fire both calls concurrently; the downloader sleeps briefly to give both tasks
        // a chance to be in flight at the same time, triggering the dedup path.
        async let url1 = cache.localURL(sourceId: "s", fileId: "dup") {
            await counter.increment()
            try await Task.sleep(nanoseconds: 30_000_000)   // 30 ms — enough overlap
            return Data(repeating: 0xAB, count: 200)
        }
        async let url2 = cache.localURL(sourceId: "s", fileId: "dup") {
            await counter.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return Data(repeating: 0xAB, count: 200)
        }
        let (a, b) = try await (url1, url2)
        XCTAssertEqual(a, b, "both callers must receive the same URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "file must exist on disk")
        let n = await counter.n
        XCTAssertEqual(n, 1, "downloader must be called exactly once; got \(n)")
    }

    /// Regression (FIX 4b): when maxBytes is smaller than the single file just written,
    /// the cache must NOT delete the file it just returned — the caller needs it.
    func test_evict_keepsJustWrittenFile_whenOverBudget() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        // maxBytes = 10: far smaller than the 200-byte file we're about to write.
        let cache = RemoteFileCache(directory: dir, maxBytes: 10)
        let url = try await cache.localURL(sourceId: "s", fileId: "big") {
            Data(repeating: 0xFF, count: 200)
        }
        // The file must still exist even though it massively exceeds the budget.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "just-written file must not be evicted even when over budget")
    }
}
