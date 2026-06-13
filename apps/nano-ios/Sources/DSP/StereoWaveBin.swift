import Foundation

/// Swift mirror of the C `NanoStereoBin`: per-channel RAW min/max envelope (−1…1, clamped) + continuous
/// band color. Feeds the close-up scope's filled min/max stereo contour (L top half, R bottom half) —
/// the nano-plugin Waveform look. Layout is 7× Float32 = 28 bytes, matching the C struct so the cache
/// serializes it verbatim. Keeping a Swift type means only `NanoDSPBridge` imports `NanoDSP`.
struct StereoWaveBin: Equatable {
    var lMin: Float
    var lMax: Float
    var rMin: Float
    var rMax: Float
    var r: Float
    var g: Float
    var b: Float
}
