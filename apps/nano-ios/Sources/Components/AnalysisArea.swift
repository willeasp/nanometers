import SwiftUI

/// The flip card's B-side (handoff §06C): a column of analysis meters (close-up scope · goniometer ·
/// spectrum — added in later phases), a floating icon-only module switcher, and the loudness badge
/// pinned top-right. No labels, no grids — the visuals melt into the card-back gradient.
///
/// Phase B stub: just the loudness badge top-right over an empty meter area. The meters + switcher
/// arrive in Phases C/D.
struct AnalysisArea: View {
    var lufs: Double?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear                                  // fills the back face

            // Short… momentary (M) BS.1770 badge, top-right of the meter area (§06C; M per user override).
            LUFSBadge(lufs: lufs)
                .padding(.top, 9).padding(.trailing, 11)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysisArea")
    }
}
