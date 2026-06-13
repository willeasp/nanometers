import Foundation
import SwiftData

/// A chosen entryway under a `Source` (handoff §09). Cloud roots persist a stable `providerFolderId`;
/// local/iCloud roots persist a security-scoped `bookmark`. A source may have many, side by side.
@Model
final class RootFolder {
    @Attribute(.unique) var id: UUID
    var sourceId: String
    var name: String
    var providerFolderId: String?
    var bookmark: Data?
    var dateAdded: Date

    init(id: UUID = UUID(), sourceId: String, name: String,
         providerFolderId: String? = nil, bookmark: Data? = nil, dateAdded: Date = .init()) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.providerFolderId = providerFolderId
        self.bookmark = bookmark
        self.dateAdded = dateAdded
    }
}
