import SwiftUI
import SwiftData

@main
struct NanoMetersApp: App {
    let container: ModelContainer
    let libIndex = LibraryIndex()

    init() {
        do {
            container = try ModelContainer(for: AppSchema.schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        MainActor.assumeIsolated {
            DemoSeed.seedIfEmpty(container.mainContext)
            SourcesMigration.runIfNeeded(container.mainContext)
            // Populate the index before the first frame so All Songs / counts don't flash 0.
            libIndex.rebuild(from: container.mainContext)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(libIndex)
        }
        .modelContainer(container)
    }
}
