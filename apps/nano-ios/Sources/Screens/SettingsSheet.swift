import SwiftUI
import SwiftData

/// App settings (handoff §03 §6 / §02). The "Waveform Display" toggles are the SINGLE source of
/// truth for what Now Playing renders — there are no equivalent controls on the player. Persisted
/// app-wide via @AppStorage. Frequency coloring is disabled when both waveforms are off.
/// "Library Sources" group (Task 6) sits above the Waveform group.
struct SettingsSheet: View {
    @AppStorage("zoomWave") private var zoomWave = false      // Close-up (Phase 5 surface; off in v1)
    @AppStorage("showWave") private var showWave = true       // Track overview
    @AppStorage("spectrum") private var spectrum = false      // Frequency coloring
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Environment(LibraryIndex.self) private var index

    private var bothOff: Bool { !zoomWave && !showWave }

    var body: some View {
        // Defer SourcesManager construction until the environment is available.
        let manager = SourcesManager(ctx: ctx, index: index)

        NavigationStack {
            Form {
                // Library Sources — above Waveform (Task 6)
                SourcesSettingsSection(manager: manager)

                Section {
                    settingsToggle("waveform.path", "Close-up (DJ scroll)", "Zoomed, scrolling waveform", $zoomWave)
                    settingsToggle("waveform", "Track overview", "Full-song scrubber", $showWave)
                    settingsToggle("paintpalette", "Frequency coloring", "Red bass · green mids · blue treble", $spectrum)
                        .disabled(bothOff).opacity(bothOff ? 0.4 : 1)
                } header: {
                    Text("Waveform Display")
                } footer: {
                    Text("Close-up is a zoomed, scrolling waveform that scrolls past a fixed playhead; Track overview is the full-song scrubber.")
                }
                .listRowBackground(Color.clear)          // let the sheet's glass material show through
            }
            .tint(Theme.accent)
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // NavigationStack destinations for Sources manager
            .navigationDestination(for: SourceDetailDest.self) { dest in
                SourceDetailView(source: dest.source, manager: manager)
            }
            .navigationDestination(for: AddSourceDest.self) { _ in
                AddSourceView(manager: manager)
            }
            .navigationDestination(for: ConnectAndDetailDest.self) { dest in
                // manager.connect was already called via simultaneousGesture; fetch the source row.
                ConnectDetailBridge(kind: dest.kind, manager: manager)
            }
            .navigationDestination(for: DriveOAuthDest.self) { _ in
                // After successful Drive OAuth, push the gdrive source detail (root-picker ready).
                ConnectDetailBridge(kind: .gdrive, manager: manager)
            }
        }
        .nmSheetGlass()
        .preferredColorScheme(.dark)
    }

    /// SettingsRow (§02): [accent icon 20] [title 16/500 + sub 12.5/text3] [iOS switch].
    private func settingsToggle(_ icon: String, _ title: String, _ sub: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(16, .medium)).foregroundStyle(Theme.text)
                    Text(sub).font(Theme.sans(12.5)).foregroundStyle(Theme.text3)
                }
            }
        }
        .accessibilityLabel(title)
    }
}
