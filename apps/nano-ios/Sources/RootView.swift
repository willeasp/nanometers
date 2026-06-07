import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("NanoMeters")
                .foregroundStyle(.white)
        }
    }
}

#Preview { RootView() }
