import Foundation
import NanoDSP
import os

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

/// Streaming momentary (400 ms) BS.1770 meter (`nano_meter_*`). The C handle is NOT thread-safe, so
/// every access is serialized by one `OSAllocatedUnfairLock`: `feed` runs on the audio tap thread,
/// `requestReset` from the main actor. The handle is created/freed/used only inside the lock — no
/// cross-thread race — and the class lives outside `@MainActor` so the tap closure calls it directly.
/// Mirrors crates/nano-dsp/smoke/smoke.swift; the Rust side is pinned by tests/ffi_abi.rs.
final class LiveLUFSMeter: @unchecked Sendable {
    private struct State {
        var handle: OpaquePointer?        // NanoMeter* (opaque)
        var rate: Double = 0
        var resetPending = false
        var momentary: Double?            // latest short-term LUFS, stashed for the 20 Hz UI ticker
        var level: Float = 0              // latest tap RMS, same stash — decouples the UI from the audio rate
    }
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    /// Drop the 3 s history on the next `feed` (call on track change / seek). Cheap; any thread.
    func requestReset() { lock.withLock { $0.resetPending = true; $0.momentary = nil; $0.level = 0 } }

    /// Interleave planar L/R, push, read momentary LUFS, and stash it (plus the tap `level`) for the UI
    /// ticker. Called on the audio tap thread, so it must NOT hop to the main actor — it only updates the
    /// lock-guarded stash; `snapshot()` is how the main actor reads it. Recreates the handle when the
    /// sample rate changes or a reset is pending. Returns / stashes nil = no reading.
    @discardableResult
    func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double,
              level: Float = 0) -> Double? {
        guard frames > 0 else { return nil }
        // Interleave OUTSIDE the lock into a `let` array (Sendable): `withLock`'s body is @Sendable and
        // cannot capture the raw L/R pointers (a warning in the project's Swift 5.10 mode, a hard error
        // under Swift 6). The array crosses the boundary cleanly; its pointer is created and used
        // entirely inside the lock. One small alloc per callback — fine for a ~1024-frame tap.
        let interleaved: [Float] = {
            var buf = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames { buf[2 * i] = left[i]; buf[2 * i + 1] = right[i] }
            return buf
        }()
        return lock.withLock { st -> Double? in
            if st.handle == nil || st.rate != sampleRate || st.resetPending {
                if let h = st.handle { nano_meter_free(h) }
                st.handle = sampleRate > 0 ? nano_meter_new(sampleRate) : nil
                st.rate = sampleRate
                st.resetPending = false
            }
            guard let h = st.handle else { st.momentary = nil; st.level = level; return nil }
            interleaved.withUnsafeBufferPointer { nano_meter_push(h, $0.baseAddress, frames) }
            let v = nano_meter_momentary(h)
            let s = v.isFinite ? v : nil
            st.momentary = s
            st.level = level
            return s
        }
    }

    /// Latest stashed readings for the main-actor UI ticker (RMS `level` + momentary LUFS `momentary`).
    /// Decouples the badge/meter from the audio-callback rate: the tap stashes ~47×/s, the ticker reads
    /// this at 20 Hz, so Now Playing invalidates at 20 Hz instead of starving the close-up's TimelineView.
    func snapshot() -> (level: Float, momentary: Double?) { lock.withLock { ($0.level, $0.momentary) } }

    /// Free the handle (call when playback stops entirely).
    func stop() { lock.withLock { st in if let h = st.handle { nano_meter_free(h) }; st.handle = nil; st.rate = 0; st.momentary = nil; st.level = 0 } }

    deinit { lock.withLock { st in if let h = st.handle { nano_meter_free(h) } } }
}
