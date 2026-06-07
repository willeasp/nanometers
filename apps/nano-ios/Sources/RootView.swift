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

            if !npOpen {                                   // REMOVE the dock (not just hide it) so only one
                VStack(spacing: 10) {                      // matched artwork exists at a time → the morph works
                    MiniPlayer(namespace: heroNS, onTapBody: { open() })
                    GlassTabBar(selection: $tab)
                }
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom))          // tab bar slides down as Now Playing rises
            }

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
