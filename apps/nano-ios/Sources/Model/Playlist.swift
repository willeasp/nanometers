import Foundation
import SwiftData

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var subtitle: String
    var dateCreated: Date
    /// Ordered membership by Track id. SwiftData relationships aren't reliably ordered (handoff §04),
    /// so order lives here and is resolved against the Track store.
    var itemIDs: [UUID]
    var coverOverrideTrackID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        dateCreated: Date = .init(),
        itemIDs: [UUID] = [],
        coverOverrideTrackID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.dateCreated = dateCreated
        self.itemIDs = itemIDs
        self.coverOverrideTrackID = coverOverrideTrackID
    }
}
