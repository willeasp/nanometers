import SwiftData
@testable import NanoMeters

/// In-memory container built from the real `AppSchema`, so tests cover the same model set the app ships.
enum TestDB {
    @MainActor
    static func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppSchema.schema, configurations: config)
        return ModelContext(container)
    }
}
