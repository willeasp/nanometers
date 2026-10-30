import SwiftUI
import SwiftData

/// "<Source> needs reconnecting" alert for a cloud track that couldn't download because its source's refresh
/// token is dead. Reconnect opens that source's settings page; if the reconnect took and the track is still
/// the current one, it resumes. `active: false` keeps a covered presenter (RootView under Now Playing) from
/// trying to show it too.
struct ReauthPrompt: ViewModifier {
    @Binding var track: Track?
    var active = true
    @Environment(\.modelContext) private var ctx
    @Environment(AudioEngine.self) private var engine
    @State private var settingsSource: Source?
    @State private var resumeTrack: Track?   // `track` handed off while the settings sheet is up

    private var source: Source? { track?.sourceId.flatMap { try? LibraryStore.source(id: $0, ctx) } }

    func body(content: Content) -> some View {
        content
            .alert("\(source?.label ?? "Source") needs reconnecting", isPresented: Binding(
                get: { active && track != nil },
                set: { if !$0 { track = nil } }
            )) {
                // Move `track` aside first so the alert can't re-arm while the sheet is up or dismissing.
                Button("Reconnect") { let s = source; resumeTrack = track; track = nil; settingsSource = s }
                Button("Cancel", role: .cancel) { track = nil }
            } message: {
                Text("Its sign-in expired. Reconnect to play tracks that aren't downloaded yet.")
            }
            .sheet(item: $settingsSource, onDismiss: resumeIfReconnected) { SettingsSheet(openSource: $0) }
    }

    private func resumeIfReconnected() {
        defer { resumeTrack = nil }
        guard let t = resumeTrack, engine.current?.id == t.id,
              let s = t.sourceId.flatMap({ try? LibraryStore.source(id: $0, ctx) }),
              s.state != SourceState.needsReauth.rawValue else { return }
        engine.reloadCurrent()
    }
}
