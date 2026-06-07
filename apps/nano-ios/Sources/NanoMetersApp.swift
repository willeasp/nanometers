import SwiftUI
import SwiftData

@main
struct NanoMetersApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Track.self, Playlist.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        MainActor.assumeIsolated { DemoSeed.seedIfEmpty(container.mainContext) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
