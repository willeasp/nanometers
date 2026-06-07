import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class PlaybackQueueTests: XCTestCase {
    private func tracks(_ n: Int) throws -> [Track] {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)
        let ts = (0..<n).map { Track(title: "T\($0)", artist: "", album: "") }
        ts.forEach(ctx.insert)
        return ts
    }

    func test_loadStartsAtChosenIndex() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue()
        let started = q.load(ts, startingAt: 1)
        XCTAssertEqual(started?.id, ts[1].id)
        XCTAssertEqual(q.current?.id, ts[1].id)
    }

    func test_advanceMovesForward() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        XCTAssertEqual(q.advance()?.id, ts[1].id)
        XCTAssertEqual(q.advance()?.id, ts[2].id)
    }

    func test_advanceAtEndStopsWhenNoRepeat() throws {
        let ts = try tracks(2)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 1)
        XCTAssertNil(q.advance())            // end of queue → stop
        XCTAssertEqual(q.current?.id, ts[1].id)  // index unchanged
    }

    func test_advanceAtEndWrapsWhenRepeat() throws {
        let ts = try tracks(2)
        var q = PlaybackQueue(isRepeat: true); _ = q.load(ts, startingAt: 1)
        XCTAssertEqual(q.advance()?.id, ts[0].id)  // wrap to 0
    }

    func test_prevRestartsWhenPastThreshold() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        if case .restartCurrent = q.goPrev(progress: 0.10) {} else { XCTFail("expected restart") }
        XCTAssertEqual(q.current?.id, ts[2].id)   // stays on current
    }

    func test_prevStepsBackWhenEarly() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        guard case .play(let t) = q.goPrev(progress: 0.02) else { return XCTFail("expected play") }
        XCTAssertEqual(t.id, ts[1].id)
        XCTAssertEqual(q.current?.id, ts[1].id)
    }

    func test_prevAtStartStaysAtZero() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        guard case .play(let t) = q.goPrev(progress: 0.0) else { return XCTFail("expected play") }
        XCTAssertEqual(t.id, ts[0].id)
        XCTAssertEqual(q.current?.id, ts[0].id)
    }

    func test_jumpToIndex() throws {
        let ts = try tracks(4)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        XCTAssertEqual(q.jump(to: 3)?.id, ts[3].id)
        XCTAssertNil(q.jump(to: 9))               // out of range → nil, index unchanged
        XCTAssertEqual(q.current?.id, ts[3].id)
    }

    func test_loadShuffledPreservesSetAndPutsChosenFirst() throws {
        let ts = try tracks(5)
        var q = PlaybackQueue()
        let first = q.loadShuffled(ts, firstIndex: 3)
        XCTAssertEqual(first?.id, ts[3].id)               // chosen track is current
        XCTAssertEqual(q.current?.id, ts[3].id)
        XCTAssertTrue(q.isShuffle)
        XCTAssertEqual(Set(ts.map(\.id)).count, 5)        // no tracks lost
    }

    func test_reshuffleKeepsCurrentAndShufflesRest() throws {
        let ts = try tracks(6)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        let current = q.current
        q.reshuffleRemaining()
        XCTAssertEqual(q.current?.id, current?.id, "current track stays put")
        XCTAssertTrue(q.isShuffle)
        XCTAssertEqual(Set(q.tracks.map(\.id)).count, 6, "no tracks lost")
    }
}
