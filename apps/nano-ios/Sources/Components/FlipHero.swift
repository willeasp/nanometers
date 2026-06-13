import SwiftUI

/// The Now Playing hero (handoff §06B): a square card whose FRONT is the album artwork and whose
/// BACK is the analysis rack. Tapping the front flips to the back; a flip-back button (top-left)
/// returns. A 3D Y-axis flip with a spring; the backface is hidden via opacity + hit-testing gates
/// (SwiftUI has no `backface-visibility`). The cover⇄mini zoom transition (RootView) is unaffected —
/// this flip happens *inside* the presented cover.
struct FlipHero<Back: View>: View {
    let artworkData: Data?
    @Binding var flipped: Bool
    @ViewBuilder var back: () -> Back

    private let radius = Theme.Radius.flipCard

    var body: some View {
        ZStack {
            front
                .opacity(flipped ? 0 : 1)
                .allowsHitTesting(!flipped)
                .accessibilityHidden(flipped)
            backFace
                .opacity(flipped ? 1 : 0)
                .allowsHitTesting(flipped)
                .accessibilityHidden(!flipped)
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: flipped)   // §07 (maps the .62s flip)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 350, maxHeight: 350)                        // §06B square, ≤350
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)     // §06B 0 28 56 black@0.42
        .frame(maxHeight: .infinity)                                // claim the leftover space, center
    }

    // FRONT — album artwork; the whole face is the flip target (§06B).
    private var front: some View {
        Group {
            if let data = artworkData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Theme.artFallback.overlay {
                    GeometryReader { g in
                        Image(systemName: "waveform")
                            .font(.system(size: g.size.width * 0.42))
                            .foregroundStyle(.white.opacity(0.22))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { flipped = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("npArtwork")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show analysis") { flipped = true }
    }

    // BACK — analysis rack on an opaque card-back gradient (§06B), pre-counter-rotated so it reads
    // correctly when the card is flipped to 180°.
    private var backFace: some View {
        ZStack {
            LinearGradient(stops: [.init(color: Theme.cardBackTop, location: 0),
                                   .init(color: Theme.cardBackMid, location: 0.58),
                                   .init(color: Theme.cardBackBottom, location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)   // ≈158°
            back()
            VStack {
                HStack {
                    Button { flipped = false } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.26), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("npFlipBack")
                    .accessibilityLabel("Show artwork")
                    Spacer()
                }
                Spacer()
            }
            .padding(11)   // §06B flip-back top:9 left:11
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))   // counter-rotate so the back reads correctly
    }
}
