import Accelerate
import Foundation

/// Pure analysis of a null test (CAM-001 A03/A04): `reference` is what the
/// emitter process produced, `captured` is what reached the device after
/// SonicRouter re-emitted it. Expected: captured[c][n] == Float(reference[c][n - lag] * gain)
/// bit for bit, for the same channel c.
struct NullTestChannelResult {
    let channel: Int
    let sourceChannel: Int
    let lag: Int
    let gain: Float
    let comparedFrames: Int
    let exactFrames: Int
    let peakResidualDBFS: Double
    let rmsResidualDBFS: Double
    /// Samples whose residual is above −60 dBFS: clicks, slips or drift.
    let glitchFrames: Int
    let firstGlitchFrame: Int?
}

struct NullTestReport {
    static let thresholdDBFS = -120.0

    var channels: [NullTestChannelResult] = []
    var referenceRMSDBFS: Double = -.infinity
    var problems: [String] = []

    var passed: Bool { problems.isEmpty && !channels.isEmpty }
}

enum NullTestAnalysis {
    static func dBFS(_ value: Double) -> Double {
        value > 0 ? 20 * log10(value) : -.infinity
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return Double(value)
    }

    /// Best lag (captured is later by `lag` frames; may be negative) and its
    /// normalised correlation, searched in −maxLag…maxLag with a probe taken
    /// from the middle of `captured`.
    static func bestLag(reference: [Float], captured: [Float], maxLag: Int) -> (lag: Int, score: Double) {
        let probeLength = min(8192, captured.count / 4)
        guard probeLength > 64, reference.count > probeLength + 2 * maxLag else { return (0, 0) }
        let probeStart = max(maxLag, (captured.count - probeLength) / 2)
        guard probeStart + probeLength <= captured.count,
            probeStart - maxLag >= 0,
            probeStart + maxLag + probeLength <= reference.count
        else { return (0, 0) }

        let probe = Array(captured[probeStart..<(probeStart + probeLength)])
        // segment[k] = reference[probeStart - maxLag + k]; result[k] = Σ segment[k+p]·probe[p]
        let segment = Array(reference[(probeStart - maxLag)..<(probeStart + maxLag + probeLength)])
        let resultCount = 2 * maxLag + 1
        var result = [Float](repeating: 0, count: resultCount)
        vDSP_conv(segment, 1, probe, 1, &result, 1, vDSP_Length(resultCount), vDSP_Length(probeLength))

        var best = 0
        for k in 1..<resultCount where result[k] > result[best] { best = k }
        let probeEnergy = probe.reduce(0.0) { $0 + Double($1) * Double($1) }
        let windowStart = best
        let window = segment[windowStart..<(windowStart + probeLength)]
        let windowEnergy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
        let denominator = (probeEnergy * windowEnergy).squareRoot()
        let score = denominator > 0 ? Double(result[best]) / denominator : 0
        // reference index = probeStart - maxLag + best ↔ captured index probeStart
        return (lag: maxLag - best, score: score)
    }

    /// The Float gain that makes the most samples match exactly, starting from
    /// the median ratio and looking a few ulps around it (plus a hint).
    static func exactGain(reference: [Float], captured: [Float], lag: Int, hint: Float?) -> Float {
        var ratios: [Float] = []
        let range = overlap(referenceCount: reference.count, capturedCount: captured.count, lag: lag)
        var n = range.lowerBound
        while n < range.upperBound, ratios.count < 4096 {
            let a = reference[n - lag]
            if abs(a) > 1e-3 { ratios.append(captured[n] / a) }
            n += max(1, range.count / 8192)
        }
        guard !ratios.isEmpty else { return hint ?? 1 }
        ratios.sort()
        var candidates: [Float] = []
        var below = ratios[ratios.count / 2]
        var above = below
        candidates.append(below)
        for _ in 0..<8 {
            below = below.nextDown
            above = above.nextUp
            candidates += [below, above]
        }
        if let hint { candidates.append(hint) }

        let sampleStride = max(1, range.count / 20_000)
        func matches(_ g: Float) -> Int {
            var count = 0
            var i = range.lowerBound
            while i < range.upperBound {
                if reference[i - lag] * g == captured[i] { count += 1 }
                i += sampleStride
            }
            return count
        }
        return candidates.max { matches($0) < matches($1) } ?? candidates[0]
    }

    static func overlap(referenceCount: Int, capturedCount: Int, lag: Int) -> Range<Int> {
        let start = max(0, lag)
        let end = min(capturedCount, referenceCount + lag)
        return start < end ? start..<end : 0..<0
    }

    static func analyze(
        reference: [[Float]],
        captured: [[Float]],
        gainHint: Float? = nil,
        maxLag: Int = 16_384
    ) -> NullTestReport {
        var report = NullTestReport()
        guard !reference.isEmpty, !captured.isEmpty else {
            report.problems.append("No hay audio capturado.")
            return report
        }
        if reference.count != captured.count {
            report.problems.append("Canales distintos: referencia \(reference.count), captura \(captured.count).")
        }

        let referenceRMS = reference.map(rms).max() ?? 0
        report.referenceRMSDBFS = dBFS(referenceRMS)
        guard referenceRMS > 1e-4 else {
            report.problems.append("La referencia (lo que emite la app de prueba) llega en silencio.")
            return report
        }
        let glitchLevel: Float = 1e-3  // −60 dBFS

        for (c, capturedChannel) in captured.enumerated() {
            guard rms(capturedChannel) > 1e-6 else {
                report.problems.append("Canal \(c + 1): la re-emisión llega en silencio.")
                continue
            }
            var best = (source: 0, lag: 0, score: -1.0)
            for (s, referenceChannel) in reference.enumerated() {
                let found = bestLag(reference: referenceChannel, captured: capturedChannel, maxLag: maxLag)
                if found.score > best.score { best = (s, found.lag, found.score) }
            }
            let source = reference[best.source]
            let gain = exactGain(reference: source, captured: capturedChannel, lag: best.lag, hint: gainHint)
            let range = overlap(referenceCount: source.count, capturedCount: capturedChannel.count, lag: best.lag)

            var exact = 0
            var peak: Float = 0
            var sumSquares = 0.0
            var glitches = 0
            var firstGlitch: Int?
            for n in range {
                let residual = capturedChannel[n] - source[n - best.lag] * gain
                if residual == 0 {
                    exact += 1
                    continue
                }
                let magnitude = abs(residual)
                peak = max(peak, magnitude)
                sumSquares += Double(magnitude) * Double(magnitude)
                if magnitude > glitchLevel {
                    glitches += 1
                    if firstGlitch == nil { firstGlitch = n }
                }
            }
            let compared = range.count
            let result = NullTestChannelResult(
                channel: c,
                sourceChannel: best.source,
                lag: best.lag,
                gain: gain,
                comparedFrames: compared,
                exactFrames: exact,
                peakResidualDBFS: dBFS(Double(peak)),
                rmsResidualDBFS: compared > 0 ? dBFS((sumSquares / Double(compared)).squareRoot()) : .infinity,
                glitchFrames: glitches,
                firstGlitchFrame: firstGlitch
            )
            report.channels.append(result)

            if compared < 4096 {
                report.problems.append("Canal \(c + 1): solapamiento insuficiente (\(compared) tramas).")
            }
            if best.source != c {
                report.problems.append("Canal \(c + 1): llega el canal \(best.source + 1) de la app (mezcla o cambio de canales).")
            }
            if result.peakResidualDBFS >= NullTestReport.thresholdDBFS {
                report.problems.append(
                    String(
                        format: "Canal %d: residuo de pico %.1f dBFS (límite %.0f).",
                        c + 1, result.peakResidualDBFS, NullTestReport.thresholdDBFS
                    ))
            }
            if let hint = gainHint, gain != hint {
                report.problems.append("Canal \(c + 1): ganancia medida \(gain), esperada \(hint).")
            }
        }
        return report
    }
}

// MARK: - Self-test (no audio hardware, no permission)

enum NullTestSelfTest {
    static func noise(channels: Int, frames: Int, seed: UInt32 = 1) -> [[Float]] {
        (0..<channels).map { c in
            var generator = NoiseGenerator(channel: c, seed: seed)
            return (0..<frames).map { _ in generator.next() }
        }
    }

    static func reemit(_ reference: [[Float]], lag: Int, gain: Float, frames: Int) -> [[Float]] {
        reference.map { channel in
            (0..<frames).map { n in
                let i = n - lag
                return i >= 0 && i < channel.count ? channel[i] * gain : 0
            }
        }
    }

    /// Returns the number of failed checks.
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "OK   " : "FALLA") \(name)")
            if !condition { failures += 1 }
        }

        let frames = 96_000
        for channels in [2, 6] {
            let reference = noise(channels: channels, frames: frames)
            let clean = reemit(reference, lag: 517, gain: 0.99, frames: frames)
            let report = NullTestAnalysis.analyze(reference: reference, captured: clean, gainHint: 0.99)
            check("\(channels) canales, retardo 517, ganancia 0,99: pasa", report.passed)
            check(
                "\(channels) canales: retardo y ganancia hallados",
                report.channels.allSatisfy { $0.lag == 517 && $0.gain == Float(0.99) })
            let noHint = NullTestAnalysis.analyze(reference: reference, captured: clean)
            check("\(channels) canales: ganancia exacta sin pista", noHint.passed)

            var dithered = clean
            for c in dithered.indices { for n in stride(from: 0, to: frames, by: 3) { dithered[c][n] += 1e-5 } }
            check(
                "\(channels) canales: ruido de −100 dBFS falla",
                !NullTestAnalysis.analyze(reference: reference, captured: dithered, gainHint: 0.99).passed)

            var swapped = clean
            swapped.swapAt(0, 1)
            check(
                "\(channels) canales: canales cambiados fallan",
                !NullTestAnalysis.analyze(reference: reference, captured: swapped, gainHint: 0.99).passed)

            var slipped = clean
            for c in slipped.indices {
                slipped[c].remove(at: frames / 2)
                slipped[c].append(0)
            }
            let slipReport = NullTestAnalysis.analyze(reference: reference, captured: slipped, gainHint: 0.99)
            check(
                "\(channels) canales: una trama perdida (deriva) falla con clics",
                !slipReport.passed && slipReport.channels.allSatisfy { $0.glitchFrames > 0 })
        }

        let stereo = noise(channels: 2, frames: frames)
        let mixed = reemit(stereo, lag: 0, gain: 1, frames: frames).map { _ in
            (0..<frames).map { n in (stereo[0][n] + stereo[1][n]) * 0.5 }
        }
        check("Mezcla a mono falla", !NullTestAnalysis.analyze(reference: stereo, captured: mixed).passed)

        let silent = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        check("Referencia en silencio falla", !NullTestAnalysis.analyze(reference: silent, captured: silent).passed)

        let other = reemit(stereo, lag: 100, gain: 0.5, frames: frames)
        check(
            "Ganancia distinta de la esperada falla",
            !NullTestAnalysis.analyze(reference: stereo, captured: other, gainHint: 0.99).passed)
        return failures
    }
}

/// Deterministic white noise at −12 dBFS peak, one independent stream per channel.
struct NoiseGenerator {
    private var state: UInt32

    init(channel: Int, seed: UInt32 = 1) {
        state = (seed &* 0x9E37_79B9) ^ (UInt32(channel + 1) &* 0x85EB_CA6B)
        if state == 0 { state = 0x1234_5678 }
    }

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        // 24-bit uniform in [-0.25, 0.25): exactly representable in Float32.
        let unit = Float(state >> 8) / Float(1 << 24)
        return (unit - 0.5) * 0.5
    }
}
