import SwiftUI

/// Snappy press feedback for plain (un-tinted) controls — Apple's standard "physical" button feel:
/// a subtle scale-down on press that springs back. Use in place of `.buttonStyle(.plain)` where the
/// press should register. The scale is a motion flourish, so it's dropped under Reduce Motion (any
/// haptic still fires); the label is otherwise rendered plain, with no system tint.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, scale: scale)
    }
    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

extension View {
    /// Elevated "liquid glass" treatment for bottom sheets (§01 Materials): the system `.regularMaterial`
    /// behind the sheet, 28pt rounded top corners, and the 1px white@14% inner-top sheen — matching the
    /// glass tab bar. The sheet's own content must stay transparent (`.scrollContentBackground(.hidden)`
    /// + clear row backgrounds) for the material to show through.
    func nmSheetGlass() -> some View {
        presentationCornerRadius(28)
            .presentationBackground {
                Rectangle().fill(.regularMaterial)
                    .overlay(alignment: .top) {                       // 1px inner-top sheen (mirrors GlassTabBar)
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Theme.glassSheen, lineWidth: 1)
                            .blur(radius: 0.5)
                            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                    }
                    .ignoresSafeArea()
            }
    }
}
