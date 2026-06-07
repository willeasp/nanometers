import SwiftUI
import SwiftData

enum SearchFilter {
    /// Case-insensitive match across title/artist/album. Empty query returns all.
    static func match(_ tracks: [Track], query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }
}

struct SearchScreen: View {
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @State private var query = ""

    private var results: [Track] { SearchFilter.match(tracks, query: query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Search").font(Theme.sans(32, .bold)).foregroundStyle(Theme.text)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Songs, artists, albums", text: $query)
                        .textFieldStyle(.plain).foregroundStyle(Theme.text)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))

                if results.isEmpty {
                    Text("No results").font(Theme.sans(15)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { t in
                            NMRow(track: t)
                            Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 50)
            .padding(.bottom, Theme.Layout.scrollBottomPadding)
        }
        .background(Theme.bg)
    }
}
