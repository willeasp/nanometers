import XCTest
import AVFoundation
@testable import NanoMeters

final class WaveformAnalyzerTests: XCTestCase {
    func test_analyzeProducesFixedDensityBinsAndFiniteLUFS() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ana_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let ref = TrackRef(bundledName: nil, bookmark: try url.bookmarkData())
        let result = try await WaveformAnalyzer().analyze(ref)

        XCTAssertEqual(result.bins.count, max(150, Int((3.0 * 10).rounded())))  // 10 bins/sec
        XCTAssertTrue(result.bins.allSatisfy { $0.peak >= 0 && $0.peak <= 1 }, "peaks normalized")
        XCTAssertTrue(result.bins.contains { $0.peak > 0.5 }, "tone should produce a loud bin")
        XCTAssertNotNil(result.integratedLUFS)
        XCTAssertEqual(result.durationSec, 3.0, accuracy: 0.05)
        XCTAssertFalse(result.key.isEmpty, "content-hash key computed")
    }

    private static func writeSine(to url: URL, seconds: Double, frequency: Double) throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let w = 2.0 * Double.pi * frequency
        for ch in 0..<2 {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(w * Double(i) / sr)) }
        }
        try file.write(from: buf)
    }
}
