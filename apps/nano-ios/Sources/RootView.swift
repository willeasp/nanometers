import SwiftUI
#if DEBUG
import SwiftData
#endif

/// App shell. The library/playlists/search content fills the screen; the mini player + glass tab bar
/// are docked via `.safeAreaInset(.bottom)` so the content insets above them automatically and the
/// dock respects the home indicator — no manual insets.
///
/// Now Playing is a `.fullScreenCover` presented with the native **zoom transition**: the mini-player
/// artwork is a `matchedTransitionSource`, and the cover uses `.navigationTransition(.zoom(...))`.
/// That gives the real artwork morph AND the interactive, finger-following swipe-to-dismiss for free
/// (iOS 18+) — no matchedGeometryEffect, no hand-rolled progress/lerp, no coordinate math.
struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()
    @State private var npOpen = false
    @Namespace private var heroNS
    #if DEBUG
    @Environment(\.modelContext) private var ctx
    #endif

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .library:   LibraryScreen(onSearch: { tab = .search })
                case .playlists: PlaylistsScreen()
                case .search:    SearchScreen()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 10) {
                if engine.current != nil {
                    MiniPlayer(artNamespace: heroNS, artSourceID: Self.artID,
                               onTapBody: { npOpen = true })
                }
                GlassTabBar(selection: $tab)
            }
        }
        .sheet(isPresented: $npOpen) {
            NowPlayingScreen(onClose: { npOpen = false })
                .navigationTransition(.zoom(sourceID: Self.artID, in: heroNS))
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)   // we have our own chevron-down
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        #if DEBUG
        .onAppear {   // headless self-test hooks: `-autoplay` docks a track, `-expand` opens Now Playing
            if ProcessInfo.processInfo.arguments.contains("-autoplay"), engine.current == nil {
                let tracks = (try? ctx.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
                if let t = tracks.first { engine.play(t, in: tracks, context: .library) }
            }
            if ProcessInfo.processInfo.arguments.contains("-expand") {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.0)); npOpen = true }
            }
        }
        #endif
    }

    /// Shared identity tying the mini-player artwork (source) to the Now Playing cover (destination).
    private static let artID = "nowPlayingArtwork"
}
