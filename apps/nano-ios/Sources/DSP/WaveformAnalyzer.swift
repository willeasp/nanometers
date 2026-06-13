import Foundation
import AVFoundation
import CryptoKit

/// A Sendable snapshot of the bits of a Track the analyzer needs, so the @Model never crosses
/// into the actor.
struct TrackRef: Sendable {
    let bundledName: String?
    let bookmark: Data?
}

/// Decodes a track ONCE off the main actor and runs nano-dsp over it: a mono mixdown for
/// `nano_dsp_analyze` (fixed density, 10 bins/sec) and deinterleaved L/R for
/// `nano_dsp_integrated_lufs` — from the same decode (handoff §05 "one decode per file, ever").
/// Also derives the content-hash cache key. Uses its OWN security scope (the engine holds its own).
actor WaveformAnalyzer {
    struct AnalysisResult: Sendable {
        let key: String
        let bins: [WaveBin]                  // overview (mono, 10/s)
        let closeUpBins: [StereoWaveBin]     // close-up scope (stereo min/max, ~50/s)
        let integratedLUFS: Double?
        let sampleRate: Double
        let durationSec: Double
    }

    enum AnalyzeError: Error { case noFile, emptyAudio, ffiFailed }

    static let binsPerSecond = 10.0
    /// Denser stereo pass for the close-up scope so the filled min/max contour reads crisply at the
    /// 3–5 s window (≈ pixel-per-column on a phone). The plugin folds at 2000 bins/s; 150/s is the
    /// cache-size/fidelity trade. Tunable.
    static let closeUpBinsPerSecond = 150.0

    func analyze(_ ref: TrackRef) throws -> AnalysisResult {
        let (url, scoped) = try Self.resolve(ref)
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let key = Self.contentKey(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat                       // Float32, deinterleaved
        let total = AVAudioFrameCount(file.length)
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            throw AnalyzeError.emptyAudio
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let sr = format.sampleRate
        guard n > 0, let chans = buffer.floatChannelData else { throw AnalyzeError.emptyAudio }
        let channelCount = Int(format.channelCount)

        // Mono mixdown + planar L/R from the single decode.
        var mono = [Float](repeating: 0, count: n)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let l = chans[0]
        let r = channelCount > 1 ? chans[1] : chans[0]
        for i in 0..<n {
            let lv = l[i], rv = r[i]
            left[i] = lv; right[i] = rv
            mono[i] = channelCount > 1 ? (lv + rv) * 0.5 : lv
        }

        let durationSec = Double(n) / sr
        let binCount = max(150, Int((durationSec * Self.binsPerSecond).rounded()))
        guard let bins = NanoDSPBridge.analyze(mono: mono, sampleRate: sr, binCount: binCount) else {
            throw AnalyzeError.ffiFailed
        }
        let closeUpCount = max(900, Int((durationSec * Self.closeUpBinsPerSecond).rounded()))
        guard let closeUpBins = NanoDSPBridge.analyzeStereo(l: left, r: right, sampleRate: sr, binCount: closeUpCount) else {
            throw AnalyzeError.ffiFailed
        }
        let lufs = NanoDSPBridge.integratedLUFS(l: left, r: right, sampleRate: sr)
        return AnalysisResult(key: key, bins: bins, closeUpBins: closeUpBins, integratedLUFS: lufs,
                              sampleRate: sr, durationSec: durationSec)
    }

    /// Resolve a track URL the same way AudioEngine does — bundled by name, else bookmark — but
    /// with the analyzer's own security scope.
    static func resolve(_ ref: TrackRef) throws -> (URL, Bool) {
        if let name = ref.bundledName, let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return (url, false)
        }
        guard let bm = ref.bookmark else { throw AnalyzeError.noFile }
        var stale = false
        let url = try URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        return (url, scoped)
    }

    /// Cheap content key: SHA256 over file byte-length + first/last 64 KB. Stable per file content
    /// without hashing the whole (possibly huge / non-resident) file.
    static func contentKey(_ url: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size: Int = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(size).littleEndian) { hasher.update(data: Data($0)) }
        let chunk = 64 * 1024
        if let head = try? fh.read(upToCount: chunk) { hasher.update(data: head) }
        if size > chunk * 2 {
            try? fh.seek(toOffset: UInt64(size - chunk))
            if let tail = try? fh.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
