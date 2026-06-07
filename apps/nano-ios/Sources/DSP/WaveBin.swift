import Foundation

/// Swift mirror of the C `NanoBin` (one analyzed bin: normalized peak 0…1 + continuous band color,
/// ADR 0001). Keeping a Swift type means only `NanoDSPBridge` ever imports `NanoDSP`; the cache,
/// renderers, and tests all stay in Swift. Layout is 4× Float32 = 16 bytes, matching the C struct
/// so the cache can serialize it verbatim.
struct WaveBin: Equatable {
    var peak: Float
    var r: Float
    var g: Float
    var b: Float
}
