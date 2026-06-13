import SwiftUI

/// The flip card's B-side (handoff §06C): a column of analysis meters (close-up scope · goniometer ·
/// spectrum) arranged by the selected modules, a floating icon-only switcher (bottom-center), and the
/// loudness badge pinned top-right. No labels, no grids — the canvases draw straight onto the card-back.
///
/// Layout rules (§06C):
/// - scope only → scope fills
/// - scope + one → scope on top, the other full-width below (≈ equal halves)
/// - scope + gonio + spectrum → scope on top; below: gonio (40%) + spectrum (60%) side by side
/// - gonio + spectrum (no scope) → stacked vertically
/// - gonio only / spectrum only → fills
struct AnalysisArea: View {
    @Binding var modulesCSV: String

    // Close-up scope
    var closeUpBins: [StereoWaveBin]
    var currentTime: () -> Double
    var duration: Double
    var coloringOn: Bool
    var windowSec: Double
    var redrawTrigger: Double
    var onScrub: (Double) -> Void

    // Live meters (goniometer + spectrum)
    var liveSamples: (Int) -> (l: [Float], r: [Float], sampleRate: Double)

    // Shared
    var isPlaying: Bool
    var active: Bool        // flipped && open — gates all meter animation (§06B)
    var lufs: Double?

    var body: some View {
        let mods = ModuleSelection.parse(modulesCSV)
        ZStack {
            meters(mods).padding(EdgeInsets(top: 12, leading: 12, bottom: 40, trailing: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            LUFSBadge(lufs: lufs).padding(.top, 9).padding(.trailing, 11)
        }
        .overlay(alignment: .bottom) {
            ModSwitch(modulesCSV: $modulesCSV).padding(.bottom, 9)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysisArea")
    }

    @ViewBuilder private func meters(_ mods: [AnalysisModule]) -> some View {
        let hasScope = mods.contains(.scope)
        let bottom = [AnalysisModule.gonio, .spectrum].filter { mods.contains($0) }
        VStack(spacing: 6) {
            if hasScope {
                meterView(.scope).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !bottom.isEmpty {
                bottomGroup(hasScope: hasScope, bottom: bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func bottomGroup(hasScope: Bool, bottom: [AnalysisModule]) -> some View {
        if hasScope && bottom.count == 2 {
            GeometryReader { geo in
                HStack(spacing: 10) {
                    meterView(.gonio).frame(width: max(0, (geo.size.width - 10) * 0.4))
                    meterView(.spectrum).frame(maxWidth: .infinity)
                }
            }
        } else if !hasScope && bottom.count == 2 {
            VStack(spacing: 10) {
                meterView(.gonio).frame(maxWidth: .infinity, maxHeight: .infinity)
                meterView(.spectrum).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            meterView(bottom[0])
        }
    }

    @ViewBuilder private func meterView(_ m: AnalysisModule) -> some View {
        switch m {
        case .scope:
            CloseUpWaveform(bins: closeUpBins, currentTime: currentTime, duration: duration,
                            coloringOn: coloringOn, isPlaying: isPlaying, redrawTrigger: redrawTrigger,
                            windowSec: windowSec, active: active, onScrub: onScrub)
        case .gonio:
            Goniometer(samples: liveSamples, isPlaying: isPlaying, active: active)
        case .spectrum:
            Spectrum(samples: liveSamples, isPlaying: isPlaying, active: active)
        }
    }
}
