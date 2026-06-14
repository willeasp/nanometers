import SwiftUI
import SwiftData

/// The OAuth config for a cloud source kind, or nil for non-OAuth kinds (local/iCloud/Dropbox).
func oauthConfig(for kind: SourceKind) -> OAuthConfig? {
    switch kind { case .gdrive: return .google; case .onedrive: return .microsoft; default: return nil }
}

// MARK: - Main List (embed in SettingsSheet as a Section)

/// The "Library Sources" section that sits at the top of the SettingsSheet form.
/// Shows connected sources → NavigationLink to detail; "Add Source…" row.
struct SourcesSettingsSection: View {
    @Query(sort: \Source.canonicalOrder) private var sources: [Source]
    @Query private var allRoots: [RootFolder]
    @Environment(LibraryIndex.self) private var index
    let manager: SourcesManager

    var body: some View {
        Section {
            ForEach(sources) { source in
                let n = allRoots.filter { $0.sourceId == source.id }.count
                let t = index.sourceCounts[source.id]?.tracks ?? 0
                NavigationLink(value: SourceDetailDest(source: source)) {
                    SourceSettingsRow(source: source, rootCount: n, trackCount: t)
                }
                .listRowBackground(Color.clear)
            }
            NavigationLink(value: AddSourceDest()) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text("Add Source…")
                        .font(Theme.sans(16))
                        .foregroundStyle(Theme.text)
                }
                .frame(minHeight: 44)
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("addSource")
        } header: {
            Text("Library Sources")
        }
    }
}

// MARK: - Nav Destinations (value types for NavigationStack)

struct SourceDetailDest: Hashable { let source: Source }
struct AddSourceDest: Hashable {}
/// Used by AddSourceRow: fire connect(kind:) then navigate to that source's detail.
struct ConnectAndDetailDest: Hashable { let kind: SourceKind }
/// Pushed after a successful OAuth connect — lands on the source detail (root-picker ready).
struct DriveOAuthDest: Hashable {}

// MARK: - Source detail view

struct SourceDetailView: View {
    let source: Source
    let manager: SourcesManager
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryIndex.self) private var index
    @Environment(\.dismiss) private var dismiss

    @Query private var allRoots: [RootFolder]
    @State private var showFolderPicker = false
    @State private var showDriveBrowser = false
    @State private var showDisconnectConfirm = false
    @State private var enumerationError: Error?
    @State private var isEnumerating = false
    // FIX E — needsReauth re-auth affordance
    @State private var isReconnecting = false
    @State private var reconnectError: String? = nil

    private var kind: SourceKind { SourceKind(rawValue: source.kind) ?? .local }
    private var state: SourceState { SourceState(rawValue: source.state) ?? .offline }
    private var roots: [RootFolder] { allRoots.filter { $0.sourceId == source.id } }
    private var counts: LibraryIndex.Counts { index.sourceCounts[source.id] ?? .init() }

    var body: some View {
        List {
            // Identity header
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                            .fill(Color(hex: source.tintHex).opacity(0.16))
                            .frame(width: 46, height: 46)
                        Image(systemName: kind.sfSymbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color(hex: source.tintHex))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.label)
                            .font(Theme.sans(16, .medium))
                            .foregroundStyle(Theme.text)
                        Text(stateSubtitle)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 8)
                    // FIX E: Reconnect button appears only when the source needs re-authentication.
                    if state == .needsReauth, let cfg = oauthConfig(for: kind), cfg.isConfigured {
                        reconnectButton
                    }
                }
                .padding(.vertical, 4)
                if let err = reconnectError {
                    Text(err)
                        .font(Theme.mono(11))
                        .foregroundStyle(.red)
                }
            }
            .listRowBackground(Color.clear)

            // Root Folders
            Section {
                if roots.isEmpty {
                    Text("Add a root folder to start browsing this source.")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.text3)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(roots) { root in
                        let rootNodeId = root.providerFolderId ?? root.nodeId ?? ""
                        let fc = index.folderCounts[rootNodeId]
                        HStack {
                            Image(systemName: "folder")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(hex: source.tintHex))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.name)
                                    .font(Theme.sans(15))
                                    .foregroundStyle(Theme.text)
                                if let fc {
                                    let f = fc.folders, t = fc.tracks
                                    Text("\(f) \(f == 1 ? "folder" : "folders") · \(t) \(t == 1 ? "track" : "tracks")")
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.text3)
                                }
                            }
                            Spacer()
                            // Always-visible inline trash (confirmation via role: .destructive alert).
                            Button(role: .destructive) {
                                manager.removeRoot(root)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(root.name)")
                        }
                        .frame(minHeight: 44)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.removeRoot(root)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("rootFolderRow-\(root.name)")
                        .listRowBackground(Color.clear)
                    }
                }

                // Add Root Folder
                if isEnumerating {
                    HStack {
                        ProgressView().tint(Theme.accent)
                        Text("Scanning folder…")
                            .font(Theme.sans(14))
                            .foregroundStyle(Theme.text3)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Button {
                        if oauthConfig(for: kind) != nil {
                            showDriveBrowser = true   // any cloud kind → folder browser
                        } else {
                            showFolderPicker = true   // local / iCloud → system folder picker
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            Text("Add Root Folder…")
                                .font(Theme.sans(15))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("addRootFolder")
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Root Folders")
            }

            if let err = enumerationError {
                Section {
                    Text("Error: \(err.localizedDescription)")
                        .font(Theme.sans(13))
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }

            // Disconnect
            Section {
                Button(role: .destructive) {
                    showDisconnectConfirm = true
                } label: {
                    Text("Disconnect Source")
                        .font(Theme.sans(15))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("disconnectSource")
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(source.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url, bookmark in
                showFolderPicker = false
                let rootName = url.lastPathComponent
                // Use the same deterministic id as DirectoryEnumerator (stable across relaunches).
                let rootId = DirectoryEnumerator.stableId(url.standardizedFileURL.path)
                let provider = LocalSourceProvider(kind: kind)
                isEnumerating = true
                enumerationError = nil
                Task { @MainActor in
                    defer { isEnumerating = false }
                    do {
                        let result = try await provider.enumerate(
                            rootBookmark: bookmark,
                            providerFolderId: nil,
                            rootName: rootName,
                            rootId: rootId
                        )
                        manager.applyEnumeration(
                            result,
                            sourceId: source.id,
                            rootName: rootName,
                            rootNodeId: rootId,
                            rootBookmark: bookmark
                        )
                    } catch {
                        enumerationError = error
                    }
                }
            }
        }
        .sheet(isPresented: $showDriveBrowser) {
            CloudFolderBrowserSheet(kind: kind, manager: manager, sourceId: source.id) {
                showDriveBrowser = false
            }
        }
        .confirmationDialog("Disconnect \(source.label)?", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                // Pass tokenStore + http so disconnect can revoke the OAuth token and delete
                // the Keychain credential before removing the Source row (FIX D / spec §14).
                manager.disconnect(sourceId: source.id,
                                   tokenStore: KeychainTokenStore(),
                                   http: URLSessionHTTPClient())
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Root folders and cached tracks will be removed from the Library. Tracks in playlists are kept.")
        }
    }

    // FIX E: "Reconnect" button for the needsReauth state — re-runs the full OAuth flow.
    @ViewBuilder
    private var reconnectButton: some View {
        if isReconnecting {
            ProgressView().tint(Theme.accent)
        } else {
            Button {
                isReconnecting = true
                reconnectError = nil
                Task { @MainActor in
                    defer { isReconnecting = false }
                    // Only shown when oauthConfig(for: kind) exists + is configured; fall back defensively.
                    let cfg = oauthConfig(for: kind) ?? .google
                    do {
                        try await manager.connectOAuth(
                            kind: kind,
                            config: cfg,
                            web: WebAuthSession(),
                            client: OAuthClient(config: cfg, http: URLSessionHTTPClient()),
                            tokenStore: KeychainTokenStore()
                        )
                    } catch WebAuthSession.Error.cancelled {
                        // User cancelled — silent
                    } catch {
                        reconnectError = error.localizedDescription
                    }
                }
            } label: {
                Text("Reconnect")
                    .font(Theme.sans(13, .medium))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reconnectSource")
        }
    }

    private var stateSubtitle: String {
        let t = counts.tracks
        switch state {
        case .connected:   return "Connected · \(t) \(t == 1 ? "track" : "tracks")"
        case .noRoots:     return "Connected · no root folders"
        case .needsReauth: return "Needs re-authentication"
        case .offline:     return "Offline"
        case .authorizing: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }
}

// MARK: - Add Source view

struct AddSourceView: View {
    let manager: SourcesManager
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Source.canonicalOrder) private var connectedSources: [Source]

    private var connectedKinds: Set<SourceKind> {
        Set(connectedSources.compactMap { SourceKind(rawValue: $0.kind) })
    }

    var body: some View {
        List {
            Section {
                ForEach(SourceKind.allCases.sorted { $0.canonicalOrder < $1.canonicalOrder }, id: \.rawValue) { kind in
                    let isConnected = connectedKinds.contains(kind)
                    AddSourceRow(kind: kind, isConnected: isConnected, manager: manager)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Available")
            } footer: {
                if connectedKinds.count == SourceKind.allCases.count {
                    Text("All available sources are connected.")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Add Source")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Individual add-source row

private struct AddSourceRow: View {
    let kind: SourceKind
    let isConnected: Bool
    let manager: SourcesManager

    // Local + iCloud are "connect directly"; gdrive/onedrive are OAuth; Dropbox coming soon.
    private var isLocalAvailable: Bool { kind == .local || kind == .icloud }
    private var oauthCfg: OAuthConfig? { oauthConfig(for: kind) }
    private var isOAuthConfigured: Bool { oauthCfg?.isConfigured == true }
    private var isOAuthNotConfigured: Bool { oauthCfg != nil && oauthCfg?.isConfigured != true }

    // OAuth state
    @State private var isConnecting = false
    @State private var connectError: String? = nil
    @State private var navigateToCloudDetail = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                    .fill(Color(hex: kind.tintHex).opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: kind.sfSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: kind.tintHex))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                    .font(Theme.sans(16, .medium))
                    .foregroundStyle(Theme.text)
                subtitleText
            }
            Spacer(minLength: 8)

            trailingControl
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        // OAuth success → push detail via programmatic navigation
        .navigationDestination(isPresented: $navigateToCloudDetail) {
            ConnectDetailBridge(kind: kind, manager: manager)
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if isConnected {
            Text("Already connected")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text3)
        } else if isLocalAvailable {
            Text("Local storage")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text3)
        } else if isOAuthConfigured {
            if let err = connectError {
                Text(err)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(.red)
            } else {
                Text(kind == .onedrive ? "Microsoft account required" : "Google account required")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
            }
        } else if isOAuthNotConfigured {
            Text(kind == .onedrive
                 ? "Add your Microsoft client ID (see docs/onedrive-setup.md)"
                 : "Add your Google client ID (see docs/google-drive-setup.md)")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text3)
        } else {
            Text("Coming soon")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text3)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isConnected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.statusGreen)
                .font(.system(size: 18))
        } else if isLocalAvailable {
            // NavigationLink fires connect then pushes to the source detail.
            // ConnectAndDetailDest is handled in SettingsSheet's navigationDestination.
            NavigationLink(value: ConnectAndDetailDest(kind: kind)) {
                Text("Connect")
                    .font(Theme.sans(14, .medium))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
            }
            .simultaneousGesture(TapGesture().onEnded {
                manager.connect(kind: kind)
            })
            .accessibilityIdentifier("connect-\(kind.rawValue)")
        } else if isOAuthConfigured, let cfg = oauthCfg {
            // Configured: show Connect pill that runs OAuth
            if isConnecting {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("connect-\(kind.rawValue)")
            } else {
                Button {
                    isConnecting = true
                    connectError = nil
                    Task { @MainActor in
                        defer { isConnecting = false }
                        do {
                            try await manager.connectOAuth(
                                kind: kind,
                                config: cfg,
                                web: WebAuthSession(),
                                client: OAuthClient(config: cfg, http: URLSessionHTTPClient()),
                                tokenStore: KeychainTokenStore()
                            )
                            navigateToCloudDetail = true
                        } catch WebAuthSession.Error.cancelled {
                            // User cancelled — silent
                        } catch {
                            connectError = error.localizedDescription
                        }
                    }
                } label: {
                    Text("Connect")
                        .font(Theme.sans(14, .medium))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connect-\(kind.rawValue)")
            }
        } else if isOAuthNotConfigured {
            // Not configured: disabled pill with "Needs setup" copy
            Text("Needs setup")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.bgElev2, in: Capsule())
                .accessibilityIdentifier("connect-\(kind.rawValue)")
        } else {
            Text("Coming soon")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.bgElev2, in: Capsule())
                .accessibilityIdentifier("connect-\(kind.rawValue)")
        }
    }
}

// MARK: - Connect+Detail bridge (used by AddSourceRow via ConnectAndDetailDest)

/// After `manager.connect(kind:)` fires, fetch the source row and show its detail.
/// The fetch runs on the first render — by the time the NavigationLink pushes us here,
/// the insert is already committed to the ModelContext.
struct ConnectDetailBridge: View {
    let kind: SourceKind
    let manager: SourcesManager
    @Environment(\.modelContext) private var ctx

    var body: some View {
        // Fetch the source row by its stable id (= kind.rawValue).
        let source = try? LibraryStore.source(id: kind.rawValue, ctx)
        if let source {
            SourceDetailView(source: source, manager: manager)
        } else {
            // Fallback: shouldn't happen (connect was called before navigation) but show gracefully.
            ContentUnavailableView("Source not found", systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - Small helper row for the main section

private struct SourceSettingsRow: View {
    let source: Source
    var rootCount: Int = 0
    var trackCount: Int = 0

    private var kind: SourceKind { SourceKind(rawValue: source.kind) ?? .local }
    private var state: SourceState { SourceState(rawValue: source.state) ?? .offline }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                    .fill(Color(hex: source.tintHex).opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: kind.sfSymbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(hex: source.tintHex))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label)
                    .font(Theme.sans(15, .medium))
                    .foregroundStyle(Theme.text)
                Text(subtitleText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)
            Circle()
                .fill(state.dotColor)
                .frame(width: 7, height: 7)
        }
        .frame(minHeight: 44)
    }

    private var subtitleText: String {
        let n = rootCount, t = trackCount
        return "\(n) root \(n == 1 ? "folder" : "folders") · \(t) \(t == 1 ? "track" : "tracks")"
    }
}

// MARK: - SourceKind helpers (local to this file)

private extension SourceKind {
    var sfSymbol: String {
        switch self {
        case .local:    "iphone"
        case .icloud:   "icloud"
        case .gdrive:   "cloud"
        case .onedrive: "cloud"
        case .dropbox:  "shippingbox"
        }
    }
}

private extension SourceState {
    var dotColor: Color {
        switch self {
        case .connected:   Theme.statusGreen
        case .needsReauth: Theme.accent
        default:           Theme.text3
        }
    }
}

// MARK: - Cloud folder browser (Task 9, generalized for OneDrive)

/// A lightweight UI value for a browsable cloud folder, decoupled from any provider's file type.
struct CloudFolder: Identifiable, Hashable { let id: String; let name: String }

/// A sheet that lets the user browse a cloud source's folders and pick one as a root.
/// Opened from SourceDetailView for any cloud kind instead of the system FolderPicker.
struct CloudFolderBrowserSheet: View {
    let kind: SourceKind
    let manager: SourcesManager
    let sourceId: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            CloudFolderBrowserView(
                kind: kind,
                manager: manager,
                sourceId: sourceId,
                parentId: "root",
                parentName: kind == .onedrive ? "OneDrive" : "My Drive",
                onPick: { _ in onDismiss() }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Lists a cloud source's folders under `parentId`, lets the user drill or pick a folder as root.
struct CloudFolderBrowserView: View {
    let kind: SourceKind
    let manager: SourcesManager
    let sourceId: String
    let parentId: String
    let parentName: String
    let onPick: (CloudFolder) -> Void

    @State private var folders: [CloudFolder] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var isEnumerating = false
    @State private var enumerationError: String? = nil

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView().tint(Theme.accent)
                    Text("Loading folders…")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.text3)
                }
                .listRowBackground(Color.clear)
            } else if let err = loadError {
                Text("Error: \(err)")
                    .font(Theme.sans(13))
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            } else if folders.isEmpty {
                Text("No folders found.")
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.text3)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(folders) { folder in
                        NavigationLink(destination: CloudFolderBrowserView(
                            kind: kind,
                            manager: manager,
                            sourceId: sourceId,
                            parentId: folder.id,
                            parentName: folder.name,
                            onPick: onPick
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 24)
                                Text(folder.name)
                                    .font(Theme.sans(15))
                                    .foregroundStyle(Theme.text)
                            }
                            .frame(minHeight: 44)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }

            if let enumErr = enumerationError {
                Section {
                    Text("Error adding root: \(enumErr)")
                        .font(Theme.sans(13))
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }

            if !isLoading {
                Section {
                    if isEnumerating {
                        HStack {
                            ProgressView().tint(Theme.accent)
                            Text("Adding root folder…")
                                .font(Theme.sans(14))
                                .foregroundStyle(Theme.text3)
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        Button {
                            pickFolder(CloudFolder(id: parentId, name: parentName))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.accent)
                                Text("Use \"\(parentName)\" as Root")
                                    .font(Theme.sans(15))
                                    .foregroundStyle(Theme.accent)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("useCloudFolder-\(parentId)")
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(parentName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadFolders() }
    }

    private func loadFolders() async {
        isLoading = true
        loadError = nil
        do {
            guard let config = oauthConfig(for: kind) else { return }
            let token = try await manager.accessToken(
                for: kind, config: config,
                client: OAuthClient(config: config, http: URLSessionHTTPClient()),
                tokenStore: KeychainTokenStore())
            switch kind {
            case .gdrive:
                let (f, _) = try await DriveAPIClient(http: URLSessionHTTPClient()).listChildren(parentId: parentId, accessToken: token)
                folders = f.map { CloudFolder(id: $0.id, name: $0.name) }
            case .onedrive:
                let (f, _) = try await GraphAPIClient(http: URLSessionHTTPClient()).listChildren(parentId: parentId, accessToken: token)
                folders = f.map { CloudFolder(id: $0.id, name: $0.name) }
            default:
                folders = []
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func pickFolder(_ folder: CloudFolder) {
        isEnumerating = true
        enumerationError = nil
        Task { @MainActor in
            defer { isEnumerating = false }
            do {
                guard let config = oauthConfig(for: kind) else { return }
                let client = OAuthClient(config: config, http: URLSessionHTTPClient())
                let tokenStore = KeychainTokenStore()
                // The factory hands back the right provider for the kind (Drive / OneDrive).
                let provider = manager.provider(for: kind, accessToken: { force in
                    try await manager.accessToken(
                        for: kind, config: config, client: client,
                        tokenStore: tokenStore, forceRefresh: force)
                })
                let result = try await provider.enumerate(
                    rootBookmark: nil,
                    providerFolderId: folder.id,
                    rootName: folder.name,
                    rootId: folder.id
                )
                manager.applyEnumeration(
                    result,
                    sourceId: sourceId,
                    rootName: folder.name,
                    rootNodeId: folder.id,
                    rootBookmark: nil,
                    providerFolderId: folder.id
                )
                onPick(folder)
            } catch {
                enumerationError = error.localizedDescription
            }
        }
    }
}
