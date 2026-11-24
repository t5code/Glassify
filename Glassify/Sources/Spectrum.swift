import Accelerate
import Foundation

/// Turns the latest audio into one energy value per bar.
/// It reproduces what preview.html did when it played a song: a Web Audio analyser (2048-point FFT, Blackman window,
/// smoothing 0.7, -100…-30 dB mapped to 0…255) followed by the preview's own `songBands` shaping, so the bars
/// move exactly as they did there.
final class Spectrum {
    private let n = 2048
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var samples: [Float]
    private var zero: [Float]
    private var re: [Float]
    private var im: [Float]
    private var smooth: [Float]
    private var bytes: [Float]
    private var wasSilent = true

    init() {
        let n = 2048
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        window = (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / Double(n)
            return Float(0.42 - 0.5 * cos(x) + 0.08 * cos(2 * x))
        }
        samples = [Float](repeating: 0, count: n)
        zero = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n)
        im = [Float](repeating: 0, count: n)
        smooth = [Float](repeating: 0, count: n / 2)
        bytes = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func reset() {
        for i in 0..<smooth.count { smooth[i] = 0 }
        wasSilent = true
    }

    /// Returns the bar energies, or nil when there is nothing new to say (silence that was already reported).
    func bands(from tap: SpotifyTap, count: Int) -> [Float]? {
        let fresh = tap.latest(into: &samples, count: n)
        if !fresh { for i in 0..<n { samples[i] = 0 } }

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))
        vDSP_DFT_Execute(setup, samples, zero, &re, &im)

        var loud = false
        let scale = 1 / Float(n)
        for k in 0..<(n / 2) {
            let mag = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale
            let s = 0.7 * smooth[k] + 0.3 * mag
            smooth[k] = s.isFinite ? s : 0
            let db = s > 0 ? 20 * log10(s) : -Float.infinity
            let b = (255.0 / 70.0 * (db + 100)).rounded(.down)
            bytes[k] = b.isFinite ? min(255, max(0, b)) : 0
            if bytes[k] > 0 { loud = true }
        }
        if !loud {
            if wasSilent { return nil }
            wasSilent = true
            return [Float](repeating: 0, count: count)
        }
        wasSilent = false

        let hz = Float(tap.sampleRate) / Float(n)
        let lo: Float = 45, hi: Float = 11000
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let f0 = lo * pow(hi / lo, Float(i) / Float(count))
            let f1 = lo * pow(hi / lo, Float(i + 1) / Float(count))
            let a = Int((f0 / hz).rounded(.down))
            let b = max(a + 1, Int((f1 / hz).rounded(.up)))
            var s: Float = 0
            for k in a..<b where k < bytes.count { s += bytes[k] }
            let v = s / Float(b - a) / 255
            out[i] = min(1, pow(v, 1.7) * (0.85 + 0.7 * Float(i) / Float(count)))
        }
        return out
    }
}
