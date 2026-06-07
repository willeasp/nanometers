import SwiftUI
import AVKit

/// AirPlay route picker for the Now Playing bottom rail (handoff §03D item 10).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.activeTintColor = UIColor(Theme.accent)
        v.tintColor = UIColor(Theme.text2)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
