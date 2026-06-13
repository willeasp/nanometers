import SwiftUI

/// The floating icon-only module switcher (handoff §06C `ModSwitch`): a tiny glass pill of three
/// toggles — scope (bars), gonio (diamond), spectrum (curve) — bottom-center of the analysis card.
/// Multi-select; at least one is always on (enforced by `ModuleSelection.toggle`). Active = accent@18%
/// fill + accent glyph; inactive = white@40% glyph.
struct ModSwitch: View {
    @Binding var modulesCSV: String

    var body: some View {
        let mods = ModuleSelection.parse(modulesCSV)
        HStack(spacing: 2) {
            ForEach(AnalysisModule.allCases) { m in
                let on = mods.contains(m)
                Button { modulesCSV = ModuleSelection.toggle(modulesCSV, m) } label: {
                    ModGlyph(module: m, on: on)
                        .frame(width: 34, height: 28)
                        .background(on ? Theme.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(m.axID)
                .accessibilityValue(on ? "on" : "off")
            }
        }
        .padding(4)
        .background(Color(hex: 0x14141A).opacity(0.4))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityIdentifier("modSwitch")
    }
}

/// Icon-only glyph for a module toggle (handoff `SwitchIcon`).
private struct ModGlyph: View {
    let module: AnalysisModule
    let on: Bool

    var body: some View {
        let color = on ? Theme.accent : Color.white.opacity(0.4)
        switch module {
        case .scope:
            let heights: [CGFloat] = [5, 9, 4, 11, 6, 8]
            HStack(spacing: 1.6) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, hgt in
                    Capsule().fill(color).frame(width: 1.7, height: hgt)
                }
            }
        case .gonio:
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(45))
        case .spectrum:
            SpectrumGlyph().stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 11)
        }
    }
}

/// A small smooth bump curve (handoff `SwitchIcon` spectrum path), normalized to a 16×11 box.
private struct SpectrumGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / 16 * w, y: rect.minY + y / 11 * h) }
        var path = Path()
        path.move(to: p(1, 9))
        path.addQuadCurve(to: p(5.5, 4), control: p(4, 9))
        path.addQuadCurve(to: p(10, 4), control: p(8, -1))
        path.addQuadCurve(to: p(15, 8), control: p(12, 4))
        return path
    }
}
