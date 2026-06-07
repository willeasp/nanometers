import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .library:   LibraryScreen(onSearch: { tab = .search })
                case .playlists: PlaylistsScreen()
                case .search:    SearchScreen()
                }
            }

            // ONE persistent player: the docked mini ↔ full-screen Now Playing is a single
            // progress-driven morph (no matchedGeometryEffect, no conditional insert/remove).
            PlayerContainer(tab: $tab)
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
