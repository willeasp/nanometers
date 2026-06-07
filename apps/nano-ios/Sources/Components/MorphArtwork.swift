import SwiftUI

/// A RESIZABLE album-art tile used only for the mini-player ↔ Now Playing `matchedGeometryEffect`
/// morph. Unlike `NMArtwork` (which hard-codes `.frame(width: size)` and so can't be shrunk by a
/// geometry match), this fills whatever frame it's given — so matchedGeometry can animate its size
/// from 44pt to 340pt. Falls back to the waveform-glyph tile for art-less tracks (the demo tracks),
/// with the glyph scaled to the current size.
struct MorphArtwork: View {
    let data: Data?
    var radius: CGFloat

    var body: some View {
        GeometryReader { geo in
            Group {
                if let data, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    Theme.artFallback.overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: geo.size.width * 0.42, weight: .regular))
                            .foregroundStyle(.white.opacity(0.22))
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}
