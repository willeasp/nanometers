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
/// (iOS 18+) — no matchedGeometryEffect, no hand-rolled progress/lerp, no coordinate math. The cover
/// covers the whole screen (no card-stack peeking the library), but the zoom transition hands its
/// content a bogus safe area (top ≈0), so we read the real device insets here — where the hierarchy
/// reports them correctly — and thread them into NowPlayingScreen.
struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()
    @State private var npOpen = false
    @State private var deviceInsets = EdgeInsets()
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
        .fullScreenCover(isPresented: $npOpen) {
            NowPlayingScreen(onClose: { npOpen = false }, safeArea: deviceInsets)
                .navigationTransition(.zoom(sourceID: Self.artID, in: heroNS))
        }
        // Read the real device insets at the root (the cover's own insets are wrong — see type doc).
        // Outermost, so `.safeAreaInset(.bottom)` above doesn't shrink the bottom we capture.
        .onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }, action: { deviceInsets = $0 })
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
