import Foundation
import SwiftData

/// Coordinates waveform availability: memory → disk cache → analyze (off-main via the actor),
/// persisting results and writing them back onto the Track on the main actor. Views call
/// `bins(for:)` from a `.task`; on a cache miss it analyzes once and de-dupes concurrent requests.
@MainActor
@Observable
final class WaveformStore {
    static let shared = WaveformStore()
    private let analyzer = WaveformAnalyzer()
    private var memory: [String: [WaveBin]] = [:]   // by content key
    private var inflight: Set<PersistentIdentifier> = []

    /// Returns the track's bins, or nil while unavailable (renderer shows "analyzing"). Side effect:
    /// persists the cache and sets `track.waveformCacheKey` / `track.integratedLUFS` on first analyze.
    @discardableResult
    func bins(for track: Track) async -> [WaveBin]? {
        let key = track.waveformCacheKey
        if !key.isEmpty, let m = memory[key] { return m }
        if !key.isEmpty, let cached = WaveformCache.load(key: key) {
            memory[key] = cached.bins
            if track.integratedLUFS == nil { track.integratedLUFS = cached.integratedLUFS }
            return cached.bins
        }
        // Analyze (de-dupe per track identity).
        guard !inflight.contains(track.persistentModelID) else { return nil }
        inflight.insert(track.persistentModelID)
        defer { inflight.remove(track.persistentModelID) }

        let ref = TrackRef(bundledName: track.bundledName, bookmark: track.bookmark)
        guard let result = try? await analyzer.analyze(ref) else { return nil }
        WaveformCache.save(key: result.key, bins: result.bins, integratedLUFS: result.integratedLUFS,
                           sampleRate: result.sampleRate, durationSec: result.durationSec)
        memory[result.key] = result.bins
        track.waveformCacheKey = result.key
        track.integratedLUFS = result.integratedLUFS
        return result.bins
    }
}
