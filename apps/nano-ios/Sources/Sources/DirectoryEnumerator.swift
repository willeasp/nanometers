import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

/// Walks a local folder tree into provider-agnostic descriptors. Pure (no SwiftData), so it's unit-
/// testable against a temp directory. Audio files only (by UTType); folder ids are stable SHA-256 hashes
/// of the path relative to the root, so re-enumeration is fully idempotent across process restarts.
enum DirectoryEnumerator {
    static let audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aif","aiff","flac","alac","caf","ogg"]

    /// Deterministic, process-restart-stable id keyed on the path relative to the picked root folder.
    /// "local:" prefix keeps the id namespace distinct from cloud provider ids.
    static func stableId(_ s: String) -> String {
        "local:" + SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func enumerate(folderURL root: URL, rootId: String, rootName: String) throws -> EnumerationResult {
        var folders: [FolderDescriptor] = []
        var tracks: [TrackDescriptor] = []
        var visited = Set<String>()
        try walk(root, id: rootId, name: rootName, parentId: nil, root: root,
                 folders: &folders, tracks: &tracks, visited: &visited)
        return EnumerationResult(folders: folders, tracks: tracks)
    }

    /// Relative path of `url` from `root` (e.g. "House/track1.wav"). Used as providerFileId for local
    /// tracks — no leading slash, root's own path produces "".
    private static func relativePath(of url: URL, root: URL) -> String {
        let rp = root.standardizedFileURL.path
        let ep = url.standardizedFileURL.path
        guard ep.hasPrefix(rp) else { return ep }
        let after = String(ep.dropFirst(rp.count))
        return after.hasPrefix("/") ? String(after.dropFirst()) : after
    }

    @MainActor
    private static func walk(_ url: URL, id: String, name: String, parentId: String?, root: URL,
                             folders: inout [FolderDescriptor], tracks: inout [TrackDescriptor],
                             visited: inout Set<String>) throws {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys))
            ?? []
        var childFolderIds: [String] = []
        var trackIds: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let rv = try? entry.resourceValues(forKeys: Set(resourceKeys))
            let isSymlink = rv?.isSymbolicLink ?? false
            let isDir = rv?.isDirectory ?? false

            // Skip symlinks (FIX 4): prevents both outright symlinks and symlink-based cycles.
            if isSymlink { continue }

            if isDir {
                // Cycle / revisit guard: standardized resolved path catches hard-link loops too.
                let canonical = entry.resolvingSymlinksInPath().standardizedFileURL.path
                guard visited.insert(canonical).inserted else { continue }

                let rel = relativePath(of: entry, root: root)
                let cid = stableId(rel)
                childFolderIds.append(cid)
                try walk(entry, id: cid, name: entry.lastPathComponent, parentId: id, root: root,
                         folders: &folders, tracks: &tracks, visited: &visited)
            } else {
                // iCloud placeholder: ".Track.mp3.icloud" → recover real name "Track.mp3"
                var audioName = entry.lastPathComponent
                var audioExt = entry.pathExtension.lowercased()
                if audioExt == "icloud", audioName.hasPrefix(".") {
                    // Strip leading "." and trailing ".icloud" to get the real filename.
                    let stripped = String(audioName.dropFirst().dropLast(".icloud".count + 1))
                    let recoveredExt = URL(fileURLWithPath: stripped).pathExtension.lowercased()
                    if Self.audioExtensions.contains(recoveredExt) {
                        audioName = stripped
                        audioExt = recoveredExt
                        // TODO (Phase 5): call fileManager.startDownloadingUbiquitousItem(at:) to
                        // trigger on-demand iCloud download before playback attempt.
                    } else {
                        continue
                    }
                }

                guard audioExtensions.contains(audioExt) else { continue }

                // providerFileId = path relative to root (e.g. "House/track1.wav")
                let relPath = relativePath(of: entry, root: root)
                // Use the recovered audioName for path-based id when it was an iCloud placeholder.
                let idPath = audioName == entry.lastPathComponent
                    ? relPath
                    : relativePath(of: entry.deletingLastPathComponent(), root: root) + (relPath.isEmpty ? "" : "/") + audioName

                let tid = stableId(idPath)
                trackIds.append(tid)
                // No per-file bookmark — playback goes through the ROOT folder's security-scoped
                // bookmark + relative path (FIX 2). TrackImporter's direct imports keep their own.
                let rawTitle = URL(fileURLWithPath: audioName).deletingPathExtension().lastPathComponent
                let title = rawTitle.replacingOccurrences(of: "_", with: " ")
                let format = URL(fileURLWithPath: audioName).pathExtension.uppercased()
                tracks.append(TrackDescriptor(id: tid, title: title, artist: "", album: "",
                                              durationSec: 0, format: format,
                                              bookmark: nil, providerFileId: idPath))
            }
        }
        folders.append(FolderDescriptor(id: id, name: name, parentId: parentId,
                                        childFolderIds: childFolderIds, trackIds: trackIds))
    }
}
