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

// MARK: - Source detail view

struct SourceDetailView: View {
    let source: Source
    let manager: SourcesManager
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryIndex.self) private var index
    @Environment(\.dismiss) private var dismiss

    @Query private var allRoots: [RootFolder]
    @State private var showFolderPicker = false
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
                        showFolderPicker = true
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

    // Only local + iCloud are available in Phase 4; cloud providers are Phase 5.
    private var isAvailable: Bool { kind == .local || kind == .icloud }

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
                Text(isConnected ? "Already connected" : (isAvailable ? "Local storage" : "Coming soon"))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)

            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.statusGreen)
                    .font(.system(size: 18))
            } else if isAvailable {
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
        .frame(minHeight: Theme.Layout.rowMinHeight)
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
