// Host smoke test: link nano-dsp's C-ABI and confirm Swift can call it and get a sane result.
import Foundation

let sr = 48_000.0
let n = Int(sr * 4.0)
var mono = [Float](repeating: 0, count: n)
for i in 0..<n {
    mono[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr))
}

// Integrated LUFS over the tone (L = R).
let lufs = nano_dsp_integrated_lufs(mono, mono, n, sr)
print("integrated LUFS = \(lufs)")
precondition(lufs > -30.0 && lufs < 0.0, "integrated LUFS implausible: \(lufs)")

// Analyze into 150 bins.
var bins = [NanoBin](repeating: NanoBin(peak: -1, r: -1, g: -1, b: -1), count: 150)
let rc = nano_dsp_analyze(mono, n, Float(sr), 150, &bins)
precondition(rc == 0, "analyze failed: \(rc)")
precondition(bins.allSatisfy { $0.peak >= 0 && $0.peak <= 1 }, "peaks not normalized")
precondition(bins.contains { $0.peak > 0.5 }, "no loud bin found")

// Streaming meter.
var inter = [Float]()
inter.reserveCapacity(n * 2)
for s in mono { inter.append(s); inter.append(s) }
let m = nano_meter_new(sr)!
nano_meter_push(m, inter, n)
let st = nano_meter_short_term(m)
print("short-term LUFS = \(st)")
precondition(st > -30.0 && st < 0.0, "short-term implausible: \(st)")
nano_meter_free(m)

print("SMOKE OK")
