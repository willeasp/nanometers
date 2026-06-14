import Foundation

/// LRU on-disk cache of downloaded provider files (handoff §08.5). Keyed by (sourceId, fileId); the cached
/// file is a normal local URL so AudioEngine/WaveformAnalyzer use it unchanged. `downloader` is injected so
/// the cache is testable without network.
actor RemoteFileCache {
    private let dir: URL; private let maxBytes: Int
    /// Dedup map: collapses concurrent downloads of the same (sourceId, fileId) to a single Task.
    private var inFlight: [String: Task<URL, Error>] = [:]
    init(directory: URL, maxBytes: Int = 512 * 1024 * 1024) {
        self.dir = directory; self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func key(_ s: String, _ f: String) -> String { "\(s)__\(f)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(s)_\(f)" }
    private func fileURL(_ s: String, _ f: String) -> URL { dir.appendingPathComponent(key(s, f)) }
    nonisolated func isCached(sourceId: String, fileId: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(("\(sourceId)__\(fileId)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).path)
    }
    func localURL(sourceId: String, fileId: String, downloader: @escaping () async throws -> Data) async throws -> URL {
        let url = fileURL(sourceId, fileId)
        // Cache hit: touch to update LRU order and return immediately.
        if FileManager.default.fileExists(atPath: url.path) { touch(url); return url }
        // Dedup: if a download for this key is already in flight, piggyback on it.
        let k = key(sourceId, fileId)
        if let existing = inFlight[k] { return try await existing.value }
        // New download: create, register, run, then always unregister.
        let task = Task<URL, Error> {
            let data = try await downloader()
            // Atomic: a disk-full / mid-write failure must not leave a truncated file that fileExists()
            // would then serve forever as a false cache hit (matches sibling WaveformCache).
            try data.write(to: url, options: .atomic)
            touch(url)
            evictIfNeeded(keepURL: url)
            return url
        }
        inFlight[k] = task
        defer { inFlight[k] = nil }
        return try await task.value
    }
    private func touch(_ url: URL) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    private func evictIfNeeded(keepURL: URL) {
        let fm = FileManager.default
        var files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = files.reduce(0) { $0 + size($1) }
        // If a single file already exceeds the entire budget, skip eviction — there's nothing to evict.
        guard total > maxBytes else { return }
        files.sort { mtime($0) < mtime($1) }   // oldest first
        var i = 0
        while total > maxBytes, i < files.count {
            let candidate = files[i]; i += 1
            // Never evict the file we just wrote.
            guard candidate.standardizedFileURL != keepURL.standardizedFileURL else { continue }
            total -= size(candidate)
            try? fm.removeItem(at: candidate)
        }
    }
}
