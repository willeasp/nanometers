import SwiftUI

/// Now Playing → ⚙ → Settings → Analysis (handoff §06E). These controls are the single source of
/// truth for the close-up coloring, its window, and whether the overview scrubber shows. Persisted
/// app-wide via @AppStorage; the module selection itself lives on the player's icon switcher.
struct SettingsSheet: View {
    @AppStorage("spectrum") private var spectrum = true        // frequency coloring (close-up only)
    @AppStorage("scopeWindow") private var scopeWindow = 4     // close-up window seconds (3/4/5)
    @AppStorage("showWave") private var showWave = true        // track overview scrubber vs plain bar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    settingsToggle("paintpalette", "Frequency coloring",
                                   "Close-up: red bass · green mids · blue treble", $spectrum)
                    windowRow
                    settingsToggle("waveform", "Track overview scrubber",
                                   "Whole-song waveform seek bar", $showWave)
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("Tap the meter icons in the player to switch between close-up, goniometer and spectrum — show one or several at once.")
                }
                .listRowBackground(Color.clear)          // let the sheet's glass material show through
            }
            .tint(Theme.accent)
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .nmSheetGlass()
        .preferredColorScheme(.dark)
    }

    /// Close-up window: title/sub + a segmented 3s/4s/5s control (mono labels), §06E.
    private var windowRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Close-up window").font(Theme.sans(16, .medium)).foregroundStyle(Theme.text)
                    Text("Seconds across the scope").font(Theme.sans(12.5)).foregroundStyle(Theme.text3)
                }
            }
            Picker("Close-up window", selection: $scopeWindow) {
                Text("3s").tag(3); Text("4s").tag(4); Text("5s").tag(5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("scopeWindowPicker")
        }
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
