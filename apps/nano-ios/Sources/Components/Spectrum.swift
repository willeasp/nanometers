import SwiftUI
import Accelerate

/// Live spectrum (handoff §06D.3): a SMOOTH filled curve — NOT bars — of 72 log-spaced FFT
/// magnitudes, temporally smoothed for fluid motion, drawn as a single quadratic-smoothed path with an
/// accent gradient fill and a bright accent top line. Fades to the floor when there's no live audio.
/// The vDSP FFT setup is created once and reused (`SpectrumAnalyzer`).
struct Spectrum: View {
    var samples: (Int) -> (l: [Float], r: [Float], sampleRate: Double)
    var isPlaying: Bool
    var active: Bool

    @State private var analyzer = SpectrumAnalyzer()

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date   // a Canvas in a TimelineView only re-renders per tick if it READS the schedule date
                let s = samples(SpectrumAnalyzer.fftSize)
                let mags = analyzer.process(l: s.l, r: s.r, live: isPlaying && !s.l.isEmpty)
                draw(ctx, size, mags: mags)
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier("spectrum")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, mags: [Float]) {
        let w = size.width, h = size.height
        guard w > 2, h > 2, mags.count > 1 else { return }
        let floorY = h - 2, topMargin: CGFloat = 3
        let n = mags.count
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) / CGFloat(n - 1) * w,
                    y: floorY - CGFloat(max(0, min(1, mags[i]))) * (floorY - topMargin))
        }
        func curve(into path: inout Path) {
            path.move(to: pt(0))
            for i in 0..<(n - 1) {
                let a = pt(i), b = pt(i + 1)
                path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            path.addLine(to: pt(n - 1))
        }

        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: floorY))
        fill.addLine(to: pt(0))
        for i in 0..<(n - 1) {
            let a = pt(i), b = pt(i + 1)
            fill.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        fill.addLine(to: pt(n - 1))
        fill.addLine(to: CGPoint(x: w, y: floorY)); fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.04)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: floorY)))

        var line = Path(); curve(into: &line)
        ctx.stroke(line, with: .color(Theme.accent.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// FFT + log-bin reduction + temporal smoothing for the spectrum. vDSP real FFT, set up once. Holds the
/// smoothed magnitudes across frames so the curve eases (V += (target−V)·0.22) and decays to the floor
/// when idle. A reference type in `@State`.
final class SpectrumAnalyzer {
    static let fftSize = 2048
    static let binCount = 72

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var smoothed = [Float](repeating: 0.04, count: binCount)
    private let edges: [Int]            // log-spaced FFT-bin boundaries, binCount+1 of them

    init() {
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        let half = Self.fftSize / 2
        var e = [Int]()
        for i in 0...Self.binCount {
            let f = Double(i) / Double(Self.binCount)
            let b = 1.0 * pow(Double(half) / 1.0, f)        // log-spaced 1…half
            e.append(min(half, max(1, Int(b.rounded()))))
        }
        edges = e
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// 72 smoothed magnitudes (0…1). Not live / too few samples → decays toward the floor.
    func process(l: [Float], r: [Float], live: Bool) -> [Float] {
        let floorV: Float = 0.04
        var target = [Float](repeating: floorV, count: Self.binCount)
        let n = min(l.count, r.count)
        if live && n >= Self.fftSize {
            let half = Self.fftSize / 2
            var mono = [Float](repeating: 0, count: Self.fftSize)
            let start = n - Self.fftSize
            for i in 0..<Self.fftSize { mono[i] = (l[start + i] + r[start + i]) * 0.5 }
            vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(Self.fftSize))

            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            var mags = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    mono.withUnsafeBytes { raw in
                        let cplx = raw.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            let scale = 1.0 / Float(Self.fftSize)
            for b in 0..<Self.binCount {
                let lo = edges[b], hi = max(edges[b] + 1, edges[b + 1])
                var sum: Float = 0, cnt: Float = 0
                for k in lo..<min(half, hi) { sum += mags[k]; cnt += 1 }
                let avg = cnt > 0 ? (sum / cnt) * scale : 0
                let db = 20 * log10(max(avg, 1e-7))           // ~ -140…0 dB
                target[b] = max(floorV, min(1, (db + 75) / 65))   // map ≈ -75…-10 dB → 0…1 (visual)
            }
        }
        for i in 0..<Self.binCount { smoothed[i] += (target[i] - smoothed[i]) * 0.22 }
        return smoothed
    }
}
