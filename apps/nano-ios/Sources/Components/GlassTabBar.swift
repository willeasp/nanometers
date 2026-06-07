import SwiftUI

enum Tab: CaseIterable {
    case library, playlists, search
    var title: String { switch self { case .library: "Library"; case .playlists: "Playlists"; case .search: "Search" } }
    var icon: String { switch self { case .library: "square.stack"; case .playlists: "music.note.list"; case .search: "magnifyingglass" } }
}

struct GlassTabBar: View {
    @Binding var selection: Tab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 24))
                        Text(tab.title)
                            .font(Theme.sans(10.5, active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Theme.accent : Theme.text2)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .top) {                       // 1px inner top sheen
            RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous)
                .stroke(Theme.glassSheen, lineWidth: 1)
                .blur(radius: 0.5)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
        }
        .shadow(color: .black.opacity(0.4), radius: 15, y: 8)
        .padding(.horizontal, 12)
    }
}
