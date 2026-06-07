import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .library:   LibraryScreen()
                case .playlists: PlaylistsScreen()
                case .search:    SearchScreen()
                }
            }

            GlassTabBar(selection: $tab)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
