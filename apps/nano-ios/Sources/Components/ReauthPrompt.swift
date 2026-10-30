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

    private var source: Source? { track?.sourceId.flatMap { try? LibraryStore.source(id: $0, ctx) } }

    func body(content: Content) -> some View {
        content
            .alert("\(source?.label ?? "Source") needs reconnecting", isPresented: Binding(
                get: { active && track != nil && settingsSource == nil },
                set: { if !$0 && settingsSource == nil { track = nil } }
            )) {
                Button("Reconnect") { settingsSource = source }
                Button("Cancel", role: .cancel) { track = nil }
            } message: {
                Text("Its sign-in expired. Reconnect to play tracks that aren't downloaded yet.")
            }
            .sheet(item: $settingsSource, onDismiss: resumeIfReconnected) { SettingsSheet(openSource: $0) }
    }

    private func resumeIfReconnected() {
        defer { track = nil }
        guard let t = track, engine.current?.id == t.id,
              let s = source, s.state != SourceState.needsReauth.rawValue else { return }
        engine.reloadCurrent()
    }
}
