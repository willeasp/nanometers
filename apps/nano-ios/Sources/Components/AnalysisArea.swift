import SwiftUI

/// The flip card's B-side (handoff §06C): a column of analysis meters (close-up scope · goniometer ·
/// spectrum) with the loudness badge pinned top-right and (Phase D) a floating icon-only module
/// switcher. No labels, no grids — the canvases draw straight onto the card-back gradient.
///
/// Phase C: the close-up scope fills the meter area. The goniometer, spectrum, and the ModSwitch +
/// layout rules arrive in Phase D.
struct AnalysisArea: View {
    var closeUpBins: [StereoWaveBin]
    var currentTime: () -> Double
    var duration: Double
    var coloringOn: Bool
    var isPlaying: Bool
    var redrawTrigger: Double
    var windowSec: Double
    var lufs: Double?
    var onScrub: (Double) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if !closeUpBins.isEmpty, duration > 0 {
                    CloseUpWaveform(bins: closeUpBins, currentTime: currentTime, duration: duration,
                                    coloringOn: coloringOn, isPlaying: isPlaying, redrawTrigger: redrawTrigger,
                                    windowSec: windowSec, onScrub: onScrub)
                } else {
                    Color.clear   // analyzing / no track
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 40, trailing: 12))   // §06C; bottom leaves room for the switcher

            // Momentary (M) BS.1770 badge, top-right of the meter area (§06C; M per user override).
            LUFSBadge(lufs: lufs)
                .padding(.top, 9).padding(.trailing, 11)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysisArea")
    }
}
