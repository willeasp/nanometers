import Foundation
import NanoDSP

/// The one place that calls the nano-dsp C-ABI (NanoDSP.xcframework). Encapsulates the unsafe
/// pointer handling and converts the C `NanoBin` to Swift `WaveBin`. ADR 0010: iOS links only
/// nano-dsp. Mirrors crates/nano-dsp/smoke/smoke.swift / include/nano_dsp.h.
enum NanoDSPBridge {
    /// Analyze `mono` PCM into `binCount` (peak, color) bins. nil on bad arguments (rc != 0).
    static func analyze(mono: [Float], sampleRate: Double, binCount: Int) -> [WaveBin]? {
        guard binCount > 0, !mono.isEmpty else { return nil }
        var out = [NanoBin](repeating: NanoBin(peak: 0, r: 0, g: 0, b: 0), count: binCount)
        let rc = mono.withUnsafeBufferPointer { p in
            nano_dsp_analyze(p.baseAddress, p.count, Float(sampleRate), binCount, &out)
        }
        guard rc == 0 else { return nil }
        return out.map { WaveBin(peak: $0.peak, r: $0.r, g: $0.g, b: $0.b) }
    }

    /// Integrated BS.1770 LUFS over stereo L/R. nil = "no reading" (-inf / non-finite).
    static func integratedLUFS(l: [Float], r: [Float], sampleRate: Double) -> Double? {
        guard !l.isEmpty, l.count == r.count else { return nil }
        let v = l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                nano_dsp_integrated_lufs(lp.baseAddress, rp.baseAddress, lp.count, sampleRate)
            }
        }
        return v.isFinite ? v : nil
    }
}
