import Foundation
import SwiftData

/// A cached node of a source's browse tree (handoff §09). Rebuildable from the provider, so it is a
/// plain id-keyed cache: children and tracks are stored as ordered id arrays, not relationships.
@Model
final class FolderNode {
    @Attribute(.unique) var id: String     // provider folder id, or a derived id for local folders
    var sourceId: String
    var name: String
    var parentId: String?                  // nil at a root folder
    var childFolderIds: [String]
    var trackIds: [UUID]
    var cursorOrEtag: String?              // delta/pagination token for background re-index
    var lastIndexed: Date?

    init(id: String, sourceId: String, name: String, parentId: String? = nil,
         childFolderIds: [String] = [], trackIds: [UUID] = [],
         cursorOrEtag: String? = nil, lastIndexed: Date? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.parentId = parentId
        self.childFolderIds = childFolderIds
        self.trackIds = trackIds
        self.cursorOrEtag = cursorOrEtag
        self.lastIndexed = lastIndexed
    }
}
