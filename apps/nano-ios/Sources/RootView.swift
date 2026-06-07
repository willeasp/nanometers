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

            VStack(spacing: 10) {
                MiniPlayer()                 // renders only when engine.current != nil
                GlassTabBar(selection: $tab)
            }
            .padding(.bottom, 10)
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
