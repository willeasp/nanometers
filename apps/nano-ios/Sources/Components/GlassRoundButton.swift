import SwiftUI

struct GlassRoundButton: View {
    let systemName: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.sans(16, .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.glassBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
