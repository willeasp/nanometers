import SwiftData

/// The single source of truth for which `@Model` types live in the container. The app and the test
/// harness both build from this, so adding a model is a one-line change here.
enum AppSchema {
    static let allModels: [any PersistentModel.Type] = [
        Track.self, Playlist.self, Source.self,
    ]
    static var schema: Schema { Schema(allModels) }
}
