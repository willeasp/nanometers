import Foundation

/// LRU on-disk cache of downloaded provider files (handoff §08.5). Keyed by (sourceId, fileId); the cached
/// file is a normal local URL so AudioEngine/WaveformAnalyzer use it unchanged. `downloader` is injected so
/// the cache is testable without network.
actor RemoteFileCache {
    private let dir: URL; private let maxBytes: Int
    init(directory: URL, maxBytes: Int = 512 * 1024 * 1024) {
        self.dir = directory; self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func key(_ s: String, _ f: String) -> String { "\(s)__\(f)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(s)_\(f)" }
    private func fileURL(_ s: String, _ f: String) -> URL { dir.appendingPathComponent(key(s, f)) }
    nonisolated func isCached(sourceId: String, fileId: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(("\(sourceId)__\(fileId)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).path)
    }
    func localURL(sourceId: String, fileId: String, downloader: () async throws -> Data) async throws -> URL {
        let url = fileURL(sourceId, fileId)
        if FileManager.default.fileExists(atPath: url.path) { touch(url); return url }
        let data = try await downloader()
        try data.write(to: url)
        touch(url)
        evictIfNeeded()
        return url
    }
    private func touch(_ url: URL) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    private func evictIfNeeded() {
        let fm = FileManager.default
        var files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = files.reduce(0) { $0 + size($1) }
        files.sort { mtime($0) < mtime($1) }   // oldest first
        var i = 0
        while total > maxBytes, i < files.count { total -= size(files[i]); try? fm.removeItem(at: files[i]); i += 1 }
    }
}
