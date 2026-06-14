import SwiftUI
import SwiftData

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
                }
                .padding(.vertical, 4)
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
                        if kind == .gdrive {
                            showDriveBrowser = true
                        } else {
                            showFolderPicker = true
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
            DriveFolderBrowserSheet(manager: manager, sourceId: source.id) {
                showDriveBrowser = false
            }
        }
        .confirmationDialog("Disconnect \(source.label)?", isPresented: $showDisconnectConfirm, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                manager.disconnect(sourceId: source.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Root folders and cached tracks will be removed from the Library. Tracks in playlists are kept.")
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

    // Local + iCloud are "connect directly" in Phase 4; gdrive is OAuth (Phase 5); others coming soon.
    private var isLocalAvailable: Bool { kind == .local || kind == .icloud }
    private var isDriveConfigured: Bool { kind == .gdrive && OAuthConfig.google.isConfigured }
    private var isDriveNotConfigured: Bool { kind == .gdrive && !OAuthConfig.google.isConfigured }

    // Drive OAuth state
    @State private var isConnecting = false
    @State private var connectError: String? = nil
    @State private var navigateToDriveDetail = false

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
        // Drive OAuth success → push detail via programmatic navigation
        .navigationDestination(isPresented: $navigateToDriveDetail) {
            ConnectDetailBridge(kind: .gdrive, manager: manager)
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
        } else if isDriveConfigured {
            if let err = connectError {
                Text(err)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(.red)
            } else {
                Text("Google account required")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
            }
        } else if isDriveNotConfigured {
            Text("Add your Google client ID (see docs/google-drive-setup.md)")
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
        } else if isDriveConfigured {
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
                                kind: .gdrive,
                                config: .google,
                                web: WebAuthSession(),
                                client: OAuthClient(config: .google, http: URLSessionHTTPClient()),
                                tokenStore: KeychainTokenStore()
                            )
                            navigateToDriveDetail = true
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
        } else if isDriveNotConfigured {
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

// MARK: - Drive folder browser (Task 9)

/// A sheet that lets the user browse Drive folders and pick one as a root.
/// Opened from SourceDetailView when kind == .gdrive instead of the system FolderPicker.
struct DriveFolderBrowserSheet: View {
    let manager: SourcesManager
    let sourceId: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            DriveFolderBrowserView(
                manager: manager,
                sourceId: sourceId,
                parentId: "root",
                parentName: "My Drive",
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

/// Lists Drive folders under `parentId`, lets the user drill or pick a folder as root.
struct DriveFolderBrowserView: View {
    let manager: SourcesManager
    let sourceId: String
    let parentId: String
    let parentName: String
    let onPick: (DriveFile) -> Void

    @State private var folders: [DriveFile] = []
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
                    ForEach(folders, id: \.id) { folder in
                        NavigationLink(destination: DriveFolderBrowserView(
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
                            pickFolder(DriveFile(id: parentId, name: parentName,
                                                 mimeType: "application/vnd.google-apps.folder"))
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
                        .accessibilityIdentifier("useDriveFolder-\(parentId)")
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
            let config = OAuthConfig.google
            let client = OAuthClient(config: config, http: URLSessionHTTPClient())
            let tokenStore = KeychainTokenStore()
            let token = try await manager.accessToken(
                for: .gdrive,
                config: config,
                client: client,
                tokenStore: tokenStore
            )
            let api = DriveAPIClient(http: URLSessionHTTPClient())
            let (drivefolders, _) = try await api.listChildren(parentId: parentId, accessToken: token)
            folders = drivefolders
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func pickFolder(_ folder: DriveFile) {
        isEnumerating = true
        enumerationError = nil
        Task { @MainActor in
            defer { isEnumerating = false }
            do {
                let config = OAuthConfig.google
                let client = OAuthClient(config: config, http: URLSessionHTTPClient())
                let tokenStore = KeychainTokenStore()
                let provider = GoogleDriveProvider(
                    api: DriveAPIClient(http: URLSessionHTTPClient()),
                    accessToken: {
                        try await manager.accessToken(
                            for: .gdrive,
                            config: config,
                            client: client,
                            tokenStore: tokenStore
                        )
                    }
                )
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
