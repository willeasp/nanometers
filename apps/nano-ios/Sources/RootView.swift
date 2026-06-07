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

            VStack(spacing: 10) {
                MiniPlayer(namespace: heroNS, onTapBody: { open() })
                GlassTabBar(selection: $tab)
            }
            .padding(.bottom, 10)
            .offset(y: npOpen ? 220 : 0)
            .opacity(npOpen ? 0 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: npOpen)

            if npOpen {
                NowPlayingScreen(namespace: heroNS, onClose: { close() })
                    .transition(.move(edge: .bottom))
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
