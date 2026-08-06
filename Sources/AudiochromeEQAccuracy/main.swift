import AudiochromeCore
import Foundation

/// Offline EQ accuracy: theoretical biquad magnitude vs steady-state sine gain through `EQProcessor`.
/// Usage:
///   swift run AudiochromeEQAccuracy [profile.txt] [sampleRate] [reference.csv]
@main
struct EQAccuracyMain {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let profilePath = args.first
            ?? "/Users/mrs/Library/CloudStorage/GoogleDrive-angelbegood@gmail.com/My Drive/Music/EQ/_test filters v2.txt"
        let sampleRate = Double(args.count > 1 ? args[1] : "") ?? 48_000
        let referencePath = args.count > 2
            ? args[2]
            : "/Users/mrs/Library/CloudStorage/GoogleDrive-angelbegood@gmail.com/My Drive/Design, Development/Github/Audiochrome/_Cursor/eq-error-Audiochrome.csv"

        let profileURL = URL(fileURLWithPath: profilePath)
        let profile = try ProfileParser.parseFile(at: profileURL)
        print("profile: \(profileURL.lastPathComponent)")
        print("sampleRate: \(Int(sampleRate))")
        print("filters: \(profile.effectiveLeft.filters.count)  preamp: \(profile.effectiveLeft.preampDB) dB")

        let freqs: [Double]
        if let refURL = optionalFile(referencePath),
           let refFreqs = try? loadReferenceFrequencies(refURL),
           !refFreqs.isEmpty {
            freqs = refFreqs
            print("reference grid: \(refURL.lastPathComponent) (\(freqs.count) pts)")
        } else {
            freqs = logSpace(20, min(20_000, sampleRate * 0.49), count: 241)
            print("reference grid: generated 241 log-spaced pts")
        }

        var rows: [(f: Double, predicted: Double, offline: Double, err: Double)] = []
        for (index, f) in freqs.enumerated() where f < sampleRate * 0.5 {
            if index % 40 == 0 { print("  measuring… \(index)/\(freqs.count)") }
            let predicted = theoreticalDB(profile: profile, frequency: f, sampleRate: sampleRate)
            let offline = measuredSineGainDB(profile: profile, frequency: f, sampleRate: sampleRate)
            rows.append((f, predicted, offline, offline - predicted))
        }

        let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("_Cursor/eq-offline-vs-theory.csv")
        try writeCSV(rows, to: outURL)

        printSummary(rows, title: "Offline EQProcessor vs theoretical magnitude")

        if let refURL = optionalFile(referencePath),
           let live = try? loadLiveErrors(refURL) {
            printSummary(
                live.map { (f: $0.f, predicted: $0.predicted, offline: $0.actual, err: $0.error) },
                title: "Your live measurement (Actual vs Predicted) — for contrast"
            )
            var pairedLive: [Double] = []
            var pairedOffline: [Double] = []
            for point in live {
                if let nearest = rows.min(by: { abs($0.f - point.f) < abs($1.f - point.f) }) {
                    pairedLive.append(point.error)
                    pairedOffline.append(nearest.err)
                }
            }
            if !pairedLive.isEmpty {
                print("\nPaired RMS on same grid:")
                print(String(format: "  live path:    %.4f dB", rms(pairedLive)))
                print(String(format: "  offline DSP:  %.4f dB", rms(pairedOffline)))
                print(String(format: "  ratio live/offline: %.1fx", rms(pairedLive) / max(rms(pairedOffline), 1e-9)))
            }
        }

        print("\nWrote \(outURL.path)")
    }

    /// Analytic cascade magnitude (same as UI / Predicted).
    private static func theoreticalDB(profile: EQProfile, frequency: Double, sampleRate: Double) -> Double {
        let dsp = EQProcessor()
        dsp.update(profile: profile, sampleRate: sampleRate)
        return dsp.magnitudeDB(atFrequency: frequency)
    }

    /// Steady-state sine → `EQProcessor` → RMS gain (dB).
    private static func measuredSineGainDB(profile: EQProfile, frequency: Double, sampleRate: Double) -> Double {
        let dsp = EQProcessor()
        dsp.update(profile: profile, sampleRate: sampleRate)

        // Settle crossfade + IIR state on silence.
        let settle = max(2048, Int(sampleRate * 0.03))
        var zeros = [Float](repeating: 0, count: settle)
        zeros.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            dsp.processInterleaved(base, frames: UInt32(buf.count), channels: 1)
        }

        // Several periods of drive, measure the last half (steady state).
        let periods = 64.0
        let samples = max(settle, Int((periods * sampleRate / frequency).rounded(.up)))
        var buffer = [Float](repeating: 0, count: samples)
        let w = 2.0 * Double.pi * frequency / sampleRate
        for i in 0..<samples {
            buffer[i] = Float(sin(w * Double(i)))
        }
        buffer.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            dsp.processInterleaved(base, frames: UInt32(buf.count), channels: 1)
        }

        let start = samples / 2
        var sumSq: Double = 0
        for i in start..<samples {
            let s = Double(buffer[i])
            sumSq += s * s
        }
        let rmsOut = sqrt(sumSq / Double(samples - start))
        // Unit-amplitude sine RMS = 1/√2
        let rmsIn = 1.0 / sqrt(2.0)
        return 20.0 * log10(max(rmsOut / rmsIn, 1e-20))
    }

    // MARK: - IO / stats

    private static func logSpace(_ a: Double, _ b: Double, count: Int) -> [Double] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return a * pow(b / a, t)
        }
    }

    private static func optionalFile(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func loadReferenceFrequencies(_ url: URL) throws -> [Double] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> Double? in
                let cols = line.split(separator: ",")
                guard let first = cols.first else { return nil }
                return Double(first)
            }
    }

    private static func loadLiveErrors(
        _ url: URL
    ) throws -> [(f: Double, predicted: Double, actual: Double, error: Double)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> (Double, Double, Double, Double)? in
                let cols = line.split(separator: ",").map(String.init)
                guard cols.count >= 4,
                      let f = Double(cols[0]),
                      let p = Double(cols[1]),
                      let a = Double(cols[2]),
                      let e = Double(cols[3])
                else { return nil }
                return (f, p, a, e)
            }
    }

    private static func writeCSV(
        _ rows: [(f: Double, predicted: Double, offline: Double, err: Double)],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var text = "Frequency (Hz),Predicted (dB),Offline DSP (dB),Error (dB)\n"
        for r in rows {
            text += String(format: "%.2f,%.4f,%.4f,%.4f\n", r.f, r.predicted, r.offline, r.err)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func printSummary(
        _ rows: [(f: Double, predicted: Double, offline: Double, err: Double)],
        title: String
    ) {
        print("\n=== \(title) ===")
        let errors = rows.map(\.err)
        print(String(format: "points: %d", rows.count))
        print(String(format: "RMS:    %.4f dB", rms(errors)))
        print(String(format: "mean:   %+.4f dB", errors.reduce(0, +) / Double(errors.count)))
        print(String(format: "max|e|: %.4f dB", errors.map(abs).max() ?? 0))
        let bands: [(String, Double, Double)] = [
            ("20-100", 20, 100),
            ("100-500", 100, 500),
            ("500-2k", 500, 2_000),
            ("2k-8k", 2_000, 8_000),
            ("8k-20k", 8_000, 20_000),
            ("<10k", 20, 10_000),
        ]
        for (name, lo, hi) in bands {
            let seg = rows.filter { $0.f >= lo && $0.f < hi }.map(\.err)
            guard !seg.isEmpty else { continue }
            let pad = name.padding(toLength: 7, withPad: " ", startingAt: 0)
            print(String(format: "  %@  RMS %.4f  max|e| %.4f", pad, rms(seg), seg.map(abs).max() ?? 0))
        }
        let worst = rows.sorted { abs($0.err) > abs($1.err) }.prefix(8)
        print("worst |error|:")
        for r in worst {
            print(String(
                format: "  %8.1f Hz  pred %+.3f  meas %+.3f  err %+.3f",
                r.f, r.predicted, r.offline, r.err
            ))
        }
    }

    private static func rms(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return sqrt(xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count))
    }
}
