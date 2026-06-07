import Foundation
import SwiftData

/// Coordinates waveform availability: memory → disk cache → analyze (off-main via the actor),
/// persisting results and writing them back onto the Track on the main actor. Views call
/// `bins(for:)` from a `.task`; concurrent callers for the SAME track join one in-flight analysis
/// (so the now-playing row and the mini player don't race to a blank result).
@MainActor
@Observable
final class WaveformStore {
    static let shared = WaveformStore()

    private let analyzer = WaveformAnalyzer()
    /// Bounded, pressure-purgeable in-memory mirror of the disk cache (keyed by content hash).
    private let memory = NSCache<NSString, BinsBox>()
    /// In-flight analyses keyed by track identity — concurrent callers await the same Task instead
    /// of bailing with nil (which would leave a non-recycled view, e.g. the mini player, blank).
    private var inflight: [PersistentIdentifier: Task<[WaveBin]?, Never>] = [:]

    private init() { memory.countLimit = 128 }

    /// Returns the track's bins, or nil if analysis failed / the file is unresolvable. Side effect
    /// on first analyze: persists the cache and sets `track.waveformCacheKey` / `integratedLUFS`.
    @discardableResult
    func bins(for track: Track) async -> [WaveBin]? {
        let key = track.waveformCacheKey
        if !key.isEmpty, let box = memory.object(forKey: key as NSString) { return box.bins }
        if !key.isEmpty, let cached = WaveformCache.load(key: key) {
            memory.setObject(BinsBox(cached.bins), forKey: key as NSString)
            if track.integratedLUFS == nil { track.integratedLUFS = cached.integratedLUFS }
            return cached.bins
        }

        // First analyze for this track — de-dupe: concurrent callers join the one Task.
        let id = track.persistentModelID
        if let task = inflight[id] { return await task.value }

        let ref = TrackRef(bundledName: track.bundledName, bookmark: track.bookmark)
        let task = Task { @MainActor () -> [WaveBin]? in
            guard let result = try? await self.analyzer.analyze(ref) else { return nil }
            WaveformCache.save(key: result.key, bins: result.bins, integratedLUFS: result.integratedLUFS,
                               sampleRate: result.sampleRate, durationSec: result.durationSec)
            self.memory.setObject(BinsBox(result.bins), forKey: result.key as NSString)
            track.waveformCacheKey = result.key
            track.integratedLUFS = result.integratedLUFS
            return result.bins
        }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        return result
    }
}

/// Boxes `[WaveBin]` so `NSCache` (which requires class keys/values) can hold it.
private final class BinsBox {
    let bins: [WaveBin]
    init(_ bins: [WaveBin]) { self.bins = bins }
}
