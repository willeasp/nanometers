import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Walks a local folder tree into provider-agnostic descriptors. Pure (no SwiftData), so it's unit-
/// testable against a temp directory. Audio files only (by UTType); folder ids are stable hashes of the
/// path relative to the root, so re-enumeration is idempotent.
enum DirectoryEnumerator {
    static let audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aif","aiff","flac","alac","caf","ogg"]

    @MainActor
    static func enumerate(folderURL root: URL, rootId: String, rootName: String) throws -> EnumerationResult {
        var folders: [FolderDescriptor] = []
        var tracks: [TrackDescriptor] = []
        try walk(root, id: rootId, name: rootName, parentId: nil, root: root,
                 folders: &folders, tracks: &tracks)
        return EnumerationResult(folders: folders, tracks: tracks)
    }

    private static func id(for url: URL, root: URL) -> String {
        let rel = url.path.replacingOccurrences(of: root.deletingLastPathComponent().path, with: "")
        return "local:" + String(rel.hashValue, radix: 16)
    }

    @MainActor
    private static func walk(_ url: URL, id: String, name: String, parentId: String?, root: URL,
                             folders: inout [FolderDescriptor], tracks: inout [TrackDescriptor]) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        var childFolderIds: [String] = []
        var trackIds: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let cid = self.id(for: entry, root: root)
                childFolderIds.append(cid)
                try walk(entry, id: cid, name: entry.lastPathComponent, parentId: id, root: root,
                         folders: &folders, tracks: &tracks)
            } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                let tid = self.id(for: entry, root: root)
                trackIds.append(tid)
                let bm = try? entry.bookmarkData()
                let title = entry.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                tracks.append(TrackDescriptor(id: tid, title: title, artist: "", album: "",
                                              durationSec: 0, format: entry.pathExtension.uppercased(),
                                              bookmark: bm, providerFileId: nil))
            }
        }
        folders.append(FolderDescriptor(id: id, name: name, parentId: parentId,
                                        childFolderIds: childFolderIds, trackIds: trackIds))
    }
}
