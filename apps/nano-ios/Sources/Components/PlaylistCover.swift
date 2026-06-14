import SwiftUI

struct PlaylistCover: View {
    let artworks: [Data?]   // ordered; may be < 4
    var size: CGFloat
    var body: some View {
        let cells = padded(artworks)
        let cell = size / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) { tile(cells[0], cell); tile(cells[1], cell) }
            HStack(spacing: 0) { tile(cells[2], cell); tile(cells[3], cell) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.mosaic, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)   // §list: 0 6 18 @.35 (radius ≈ CSS blur/2)
    }
    private func tile(_ data: Data?, _ s: CGFloat) -> some View { NMArtwork(data: data, size: s, radius: 0) }
    private func padded(_ a: [Data?]) -> [Data?] {
        if a.isEmpty { return Array(repeating: nil, count: 4) }
        var out = Array(a.prefix(4))
        while out.count < 4 { out.append(a.last!) }
        return out
    }
}
