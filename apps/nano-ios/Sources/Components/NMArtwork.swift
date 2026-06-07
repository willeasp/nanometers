import SwiftUI

struct NMArtwork: View {
    let data: Data?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Theme.artFallback
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.42, weight: .regular))
                            .foregroundStyle(.white.opacity(0.22))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}
