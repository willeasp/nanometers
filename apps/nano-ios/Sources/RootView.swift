import SwiftUI
import SwiftData

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
    @State private var libNav = LibraryNav()
    @Namespace private var heroNS
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryIndex.self) private var libIndex

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
                GlassTabBar(selection: $tab, onReselect: { t in
                    if t == .library { libNav.reset() }
                })
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
        .environment(libNav)
        .environment(libIndex)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Belt-and-suspenders initial rebuild (index is also pre-populated in NanoMetersApp.init).
        .task {
            libIndex.rebuild(from: ctx)
            // Wire the remote URL provider so cloud tracks download to the on-disk cache before play.
            // Guard on isConfigured: if no Google client ID is set, Drive Connect is disabled
            // anyway, so we never get a cloud track with a providerFileId to resolve.
            if OAuthConfig.google.isConfigured {
                engine.remoteURLProvider = makeRemoteURLProvider(ctx: ctx, index: libIndex)
            }
        }
        // Rebuild on any SwiftData save — covers in-place Source.state flips, RootFolder add/remove,
        // and track imports; more reliable than watching collection .count deltas.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            libIndex.rebuild(from: ctx)
        }
        // Task 6: Go-to-Source from a sheet/NowPlaying flips to the Library tab
        .onChange(of: libNav.switchToLibraryToken) { tab = .library }
        // Belt-and-suspenders: clear stale highlight when leaving the Library tab.
        .onChange(of: tab) { _, newTab in if newTab != .library { libNav.highlightTrackId = nil } }
        #if DEBUG
        .onAppear {   // headless self-test hooks: `-autoplay` docks a track, `-expand` opens Now Playing
            if ProcessInfo.processInfo.arguments.contains("-autoplay"), engine.current == nil {
                let tracks = (try? ctx.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
                // Prefer bundled tracks so -autoplay is deterministic regardless of leftover cloud
                // tracks from other UI tests (e.g. DriveMockFlowUITests leaves orphaned rows).
                let bundled = tracks.filter { $0.bundledName != nil }
                let list = bundled.isEmpty ? tracks : bundled
                if let t = list.first { engine.play(t, in: list, context: .library) }
            }
            if ProcessInfo.processInfo.arguments.contains("-expand") {
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.0)); npOpen = true }
            }
            // `-mock-drive`: plant a Google Drive source with a fixed 2-level tree (no OAuth/network).
            // Only inserts if no gdrive source exists yet, so it's safe on repeat launches.
            if ProcessInfo.processInfo.arguments.contains("-mock-drive") {
                let mgr = SourcesManager(ctx: ctx, index: libIndex)
                mgr.connect(kind: .gdrive)
                mgr.applyEnumeration(MockSourceProvider.fixedResult,
                                     sourceId: SourceKind.gdrive.rawValue,
                                     rootName: MockSourceProvider.rootName,
                                     rootNodeId: MockSourceProvider.rootId,
                                     rootBookmark: nil,
                                     providerFolderId: MockSourceProvider.rootId)
            }
            // `-clear-cloud-sources`: remove all non-local sources, their trees, and orphaned
            // cloud Track rows (no bundledName/bookmark/folderBookmark) — teardown for UI tests.
            // Track rows are kept on normal disconnect (playlists); tests don't care about playlists.
            if ProcessInfo.processInfo.arguments.contains("-clear-cloud-sources") {
                let mgr = SourcesManager(ctx: ctx, index: libIndex)
                for kind in SourceKind.allCases where kind != .local && kind != .icloud {
                    mgr.disconnect(sourceId: kind.rawValue)
                }
                // Delete cloud Track rows that have no local file handle so they don't
                // pollute -autoplay or waveform analysis in subsequent tests.
                let orphans = ((try? ctx.fetch(FetchDescriptor<Track>())) ?? []).filter {
                    $0.bundledName == nil && $0.bookmark == nil && $0.folderBookmark == nil
                }
                orphans.forEach { ctx.delete($0) }
                try? ctx.save()
            }
        }
        #endif
    }

    /// Shared identity tying the mini-player artwork (source) to the Now Playing cover (destination).
    private static let artID = "nowPlayingArtwork"
}

// MARK: - Remote URL provider factory (Task 11)

/// Builds the `remoteURLProvider` closure wired into `AudioEngine`. Downloads the cloud track's file to
/// the on-disk LRU cache via `RemoteFileCache`, then returns the local URL so `AudioEngine`/
/// `WaveformAnalyzer` consume it exactly like a local file. Called only for tracks where
/// `AudioEngine.needsRemotePrep` returns true (cloud tracks with `providerFileId` set).
///
/// Only assembled when `OAuthConfig.google.isConfigured` so the placeholder client ID never triggers
/// a live network call (no token exists, and Drive Connect is disabled until the user sets a real id).
@MainActor
private func makeRemoteURLProvider(ctx: ModelContext, index: LibraryIndex) -> (Track) async -> URL? {
    // The cache directory lives in Caches/remote — eviction by the LRU (512 MB default).
    let cacheDir = (try? FileManager.default.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        .map { $0.appendingPathComponent("remote", isDirectory: true) }

    return { track in
        guard let fileId = track.providerFileId,
              let sourceId = track.sourceId else { return nil }

        // Resolve the source kind from the Track's sourceId to pick the right OAuthConfig.
        let kind: SourceKind
        if let k = SourceKind(rawValue: sourceId) { kind = k }
        else { return nil }

        guard kind == .gdrive else {
            // Non-Drive cloud providers not yet wired; return nil (AudioEngine will log).
            return nil
        }

        guard let dir = cacheDir else { return nil }
        let cache = RemoteFileCache(directory: dir)

        // Build a fresh SourcesManager / OAuthClient / token store each call (stateless);
        // TokenRefreshCoordinator.shared serialises concurrent refreshes across all SourcesManager instances.
        let mgr = SourcesManager(ctx: ctx, index: index)
        let config = OAuthConfig.google
        let oauthClient = OAuthClient(config: config, http: URLSessionHTTPClient())
        let tokenStore = KeychainTokenStore()

        /// Helper: download `fileId` with `accessToken`, returning raw Data.
        /// Throws an NSError on non-200; callers detect 401 to trigger a forced refresh+retry.
        func download(accessToken: String) async throws -> Data {
            let req = DriveAPIClient.mediaRequest(fileId: fileId, accessToken: accessToken, offset: 0)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "RemoteURLProvider", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "No HTTP response downloading \(fileId)"])
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "RemoteURLProvider", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) downloading \(fileId)"])
            }
            return data
        }

        do {
            let token = try await mgr.accessToken(for: kind, config: config,
                                                   client: oauthClient,
                                                   tokenStore: tokenStore)
            let url = try await cache.localURL(sourceId: sourceId, fileId: fileId) {
                do {
                    return try await download(accessToken: token)
                } catch let err as NSError where err.code == 401 {
                    // Token expired mid-download → force a single refresh and retry once.
                    let fresh = try await mgr.accessToken(for: kind, config: config,
                                                          client: oauthClient,
                                                          tokenStore: tokenStore,
                                                          forceRefresh: true)
                    return try await download(accessToken: fresh)
                }
            }
            return url
        } catch {
            NSLog("[remoteURLProvider] failed for \(track.title): \(error)")
            return nil
        }
    }
}
