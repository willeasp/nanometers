import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()
    @State private var npOpen = false
    @Namespace private var heroNS

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

            // The dock and Now Playing are mutually exclusive (one matched artwork at a time) and use
            // the DEFAULT (opacity) transition — NOT .move, which would drag the hero along and fight
            // the geometry match. matchedGeometryEffect alone morphs the artwork between the two.
            if !npOpen {
                VStack(spacing: 10) {
                    MiniPlayer(namespace: heroNS, onTapBody: { open() })
                    GlassTabBar(selection: $tab)
                }
                .padding(.bottom, 10)
            }

            if npOpen {
                NowPlayingScreen(namespace: heroNS, onClose: { close() })
                    .zIndex(1)
            }
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func open()  { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { npOpen = true } }
    private func close() { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { npOpen = false } }
}
