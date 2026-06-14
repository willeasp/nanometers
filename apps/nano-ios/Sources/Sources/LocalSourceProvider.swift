import Foundation

/// Implements `SourceProvider` for `.local` (On My iPhone) and `.icloud` (iCloud Drive).
/// Resolves a security-scoped bookmark, starts access, enumerates via `DirectoryEnumerator`, then stops.
/// For iCloud in v1 a plain FileManager enumeration after the picker grants access is sufficient;
/// NSFileCoordinator reads are deferred to Phase 5.
@MainActor
final class LocalSourceProvider: SourceProvider {
    let kind: SourceKind

    init(kind: SourceKind) {
        precondition(kind == .local || kind == .icloud, "LocalSourceProvider only handles .local/.icloud")
        self.kind = kind
    }

    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult {
        guard let bookmark = rootBookmark else {
            throw LocalProviderError.missingBookmark
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw LocalProviderError.accessDenied(url)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try DirectoryEnumerator.enumerate(folderURL: url, rootId: rootId, rootName: rootName)
    }
}

enum LocalProviderError: Error, LocalizedError {
    case missingBookmark
    case accessDenied(URL)

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "No security-scoped bookmark provided for local enumeration."
        case .accessDenied(let url):
            return "Could not start security-scoped access to \(url.lastPathComponent)."
        }
    }
}
