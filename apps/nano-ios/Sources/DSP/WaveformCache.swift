import Foundation

/// On-disk cache of a track's analyzed bins, keyed by content hash, under the purgeable Caches dir
/// (regenerable data — never Application Support). Format (v2): a fixed header, then `monoCount` × 16
/// bytes of `WaveBin` (overview, 4× Float32 LE), then `stereoCount` × 28 bytes of `StereoWaveBin`
/// (close-up, 7× Float32 LE). A miss, a purge, or a version mismatch returns nil so the renderer shows
/// an "analyzing" state and re-analyzes. v1 files (mono only) fail the version check → transparent
/// re-analysis.
enum WaveformCache {
    struct Loaded: Equatable {
        let bins: [WaveBin]
        let closeUpBins: [StereoWaveBin]
        let integratedLUFS: Double?
    }

    private static let magic: UInt32 = 0x324D574E   // "NMW2" LE
    private static let version: UInt16 = 2

    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ key: String) -> URL { dir.appendingPathComponent("\(key).nmwave") }

    static func save(key: String, bins: [WaveBin], closeUpBins: [StereoWaveBin],
                     integratedLUFS: Double?, sampleRate: Double, durationSec: Double) {
        guard !key.isEmpty else { return }
        var data = Data()
        func put<T>(_ v: T) { var v = v; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        put(magic.littleEndian); put(version.littleEndian)
        put(Float(sampleRate).bitPattern.littleEndian)
        put(durationSec.bitPattern.littleEndian)
        // -inf sentinel encodes "no reading".
        put((integratedLUFS ?? -Double.infinity).bitPattern.littleEndian)
        put(UInt32(bins.count).littleEndian)
        bins.forEach { put($0.peak.bitPattern.littleEndian); put($0.r.bitPattern.littleEndian)
                       put($0.g.bitPattern.littleEndian); put($0.b.bitPattern.littleEndian) }
        put(UInt32(closeUpBins.count).littleEndian)
        closeUpBins.forEach {
            put($0.lMin.bitPattern.littleEndian); put($0.lMax.bitPattern.littleEndian)
            put($0.rMin.bitPattern.littleEndian); put($0.rMax.bitPattern.littleEndian)
            put($0.r.bitPattern.littleEndian); put($0.g.bitPattern.littleEndian); put($0.b.bitPattern.littleEndian)
        }
        try? data.write(to: file(key), options: .atomic)
    }

    static func load(key: String) -> Loaded? {
        guard !key.isEmpty, let data = try? Data(contentsOf: file(key)), data.count >= 30 else { return nil }
        var off = 0
        func get<T>(_ t: T.Type, _ size: Int) -> T? {
            guard off + size <= data.count else { return nil }
            let v = data.subdata(in: off..<off+size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            off += size; return v
        }
        guard let m: UInt32 = get(UInt32.self, 4), m == magic,
              let v: UInt16 = get(UInt16.self, 2), v == version,
              let _: UInt32 = get(UInt32.self, 4),                 // sampleRate bits
              let _: UInt64 = get(UInt64.self, 8),                 // durationSec bits (unused on load)
              let lufsBits: UInt64 = get(UInt64.self, 8),
              let monoCount: UInt32 = get(UInt32.self, 4) else { return nil }
        var bins: [WaveBin] = []; bins.reserveCapacity(Int(monoCount))
        for _ in 0..<Int(monoCount) {
            guard let p: UInt32 = get(UInt32.self, 4), let r: UInt32 = get(UInt32.self, 4),
                  let g: UInt32 = get(UInt32.self, 4), let b: UInt32 = get(UInt32.self, 4) else { return nil }
            bins.append(WaveBin(peak: Float(bitPattern: p), r: Float(bitPattern: r),
                                g: Float(bitPattern: g), b: Float(bitPattern: b)))
        }
        guard let stereoCount: UInt32 = get(UInt32.self, 4) else { return nil }
        var closeUp: [StereoWaveBin] = []; closeUp.reserveCapacity(Int(stereoCount))
        for _ in 0..<Int(stereoCount) {
            guard let lmin: UInt32 = get(UInt32.self, 4), let lmax: UInt32 = get(UInt32.self, 4),
                  let rmin: UInt32 = get(UInt32.self, 4), let rmax: UInt32 = get(UInt32.self, 4),
                  let r: UInt32 = get(UInt32.self, 4), let g: UInt32 = get(UInt32.self, 4),
                  let b: UInt32 = get(UInt32.self, 4) else { return nil }
            closeUp.append(StereoWaveBin(lMin: Float(bitPattern: lmin), lMax: Float(bitPattern: lmax),
                                         rMin: Float(bitPattern: rmin), rMax: Float(bitPattern: rmax),
                                         r: Float(bitPattern: r), g: Float(bitPattern: g), b: Float(bitPattern: b)))
        }
        let lufs = Double(bitPattern: lufsBits)
        return Loaded(bins: bins, closeUpBins: closeUp, integratedLUFS: lufs.isFinite ? lufs : nil)
    }

    static func remove(key: String) { try? FileManager.default.removeItem(at: file(key)) }
}
