import Foundation
import SwiftData

/// A connected storage provider account (handoff §09). String-id keyed (`"local"`/`"icloud"`/`"gdrive"`);
/// roots/folders/tracks reference it by `sourceId`, not a SwiftData relationship.
@Model
final class Source {
    @Attribute(.unique) var id: String
    var kind: String            // SourceKind.rawValue
    var label: String
    var tintHex: String
    var state: String           // SourceState.rawValue
    var authRef: String?        // Keychain account key (cloud only); never the token itself
    var canonicalOrder: Int

    init(id: String, kind: SourceKind, state: SourceState, authRef: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.label = kind.label
        self.tintHex = kind.tintHex
        self.state = state.rawValue
        self.authRef = authRef
        self.canonicalOrder = kind.canonicalOrder
    }
}
