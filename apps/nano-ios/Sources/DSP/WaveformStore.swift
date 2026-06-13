import Foundation
import SwiftData

/// Coordinates waveform availability: memory → disk cache → analyze (off-main via the actor),
/// persisting results and writing them back onto the Track on the main actor. Views call
/// `bins(for:)` (overview) or `closeUpBins(for:)` (close-up scope) from a `.task`; concurrent callers
/// for the SAME track join one in-flight analysis (so the now-playing row and the mini player don't
/// race to a blank result). One analyze produces both arrays — they share one cache entry.
@MainActor
@Observable
final class WaveformStore {
    static let shared = WaveformStore()

    private let analyzer = WaveformAnalyzer()
    /// Bounded, pressure-purgeable in-memory mirror of the disk cache (keyed by content hash).
    private let memory = NSCache<NSString, CacheBox>()
    /// In-flight analyses keyed by track identity — concurrent callers await the same Task instead
    /// of bailing with nil (which would leave a non-recycled view, e.g. the mini player, blank).
    private var inflight: [PersistentIdentifier: Task<CacheBox?, Never>] = [:]

    private init() { memory.countLimit = 128 }

    /// Overview bins, or nil if analysis failed / the file is unresolvable.
    @discardableResult
    func bins(for track: Track) async -> [WaveBin]? { await entry(for: track)?.bins }

    /// Close-up scope bins (stereo min/max), or nil if analysis failed / the file is unresolvable.
    @discardableResult
    func closeUpBins(for track: Track) async -> [StereoWaveBin]? { await entry(for: track)?.closeUp }

    /// Shared resolve: memory → disk → analyze. Side effect on first analyze: persists the cache and
    /// sets `track.waveformCacheKey` / `integratedLUFS`.
    private func entry(for track: Track) async -> CacheBox? {
        let key = track.waveformCacheKey
        if !key.isEmpty, let box = memory.object(forKey: key as NSString) { return box }
        if !key.isEmpty, let cached = WaveformCache.load(key: key) {
            let box = CacheBox(bins: cached.bins, closeUp: cached.closeUpBins)
            memory.setObject(box, forKey: key as NSString)
            if track.integratedLUFS == nil { track.integratedLUFS = cached.integratedLUFS }
            return box
        }

        // First analyze for this track — de-dupe: concurrent callers join the one Task.
        let id = track.persistentModelID
        if let task = inflight[id] { return await task.value }

        let ref = TrackRef(bundledName: track.bundledName, bookmark: track.bookmark)
        let task = Task { @MainActor () -> CacheBox? in
            guard let result = try? await self.analyzer.analyze(ref) else { return nil }
            WaveformCache.save(key: result.key, bins: result.bins, closeUpBins: result.closeUpBins,
                               integratedLUFS: result.integratedLUFS,
                               sampleRate: result.sampleRate, durationSec: result.durationSec)
            let box = CacheBox(bins: result.bins, closeUp: result.closeUpBins)
            self.memory.setObject(box, forKey: result.key as NSString)
            track.waveformCacheKey = result.key
            track.integratedLUFS = result.integratedLUFS
            return box
        }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        return result
    }
}

/// Boxes the analyzed arrays so `NSCache` (which requires class values) can hold them.
private final class CacheBox {
    let bins: [WaveBin]
    let closeUp: [StereoWaveBin]
    init(bins: [WaveBin], closeUp: [StereoWaveBin]) { self.bins = bins; self.closeUp = closeUp }
}
