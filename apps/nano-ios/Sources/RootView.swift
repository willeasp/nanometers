import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library

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

            GlassTabBar(selection: $tab)
                .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
