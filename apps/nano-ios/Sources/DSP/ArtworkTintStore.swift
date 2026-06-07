import SwiftUI
import CoreImage
import UIKit
import SwiftData

/// Extracts a track's dominant tint (1×1 area-average of its embedded artwork) once, caches the hex
/// on `Track.artworkTintHex`, and serves it as a `Color`. Mirrors `WaveformStore`'s once-per-track +
/// inflight-dedupe shape. No artwork → `Theme.bgElev2` (the neutral first-run case; demo tracks have
/// no art). The CoreImage work runs off the main actor.
@MainActor
@Observable
final class ArtworkTintStore {
    static let shared = ArtworkTintStore()
    private var inflight: Set<PersistentIdentifier> = []

    /// The gradient top-stop color for `track`. Cache hit → parse; miss → extract + persist; no art → fallback.
    func tint(for track: Track) async -> Color {
        if let hex = track.artworkTintHex { return Color(hex: hex) }
        guard let data = track.artworkData else { return Theme.bgElev2 }

        let id = track.persistentModelID
        guard !inflight.contains(id) else { return Theme.bgElev2 }
        inflight.insert(id); defer { inflight.remove(id) }

        guard let hex = await Task.detached(priority: .utility, operation: { Self.averageHex(data) }).value else {
            return Theme.bgElev2
        }
        track.artworkTintHex = hex
        return Color(hex: hex)
    }

    /// Nonisolated 1×1 CIAreaAverage → "#RRGGBB" (nil on undecodable data). Safe to call off-main.
    nonisolated static func averageHex(_ data: Data) -> String? {
        guard let ui = UIImage(data: data), let cg = ui.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }
}
