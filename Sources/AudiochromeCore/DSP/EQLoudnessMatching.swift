import Foundation

/// Squiglink-compatible loudness matching for A/B compare (ISO 226:2003 phon offset).
/// When EQ is bypassed, apply `bypassMatchGainDB` so dry playback matches EQ loudness.
public enum EQLoudnessMatching {
    /// Default Squiglink normalize target (phon).
    public static let defaultTargetPhon: Double = 60

    /// Log-spaced frequencies matching `EQProcessor.frequencyResponseCurve`.
    public static func logSpacedFrequencies(
        pointCount: Int = 96,
        sampleRate: Double = 48_000
    ) -> [Double] {
        let count = max(pointCount, 2)
        let fMin = 20.0
        let fMax = min(20_000.0, sampleRate * 0.49)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return fMin * pow(fMax / fMin, t)
        }
    }

    /// Flat-path gain (dB) so dry audio matches the perceived loudness of `eqCurveDB`.
    public static func bypassMatchGainDB(
        eqCurveDB: [Double],
        frequenciesHz: [Double],
        targetPhon: Double = defaultTargetPhon
    ) -> Double {
        precondition(eqCurveDB.count == frequenciesHz.count)
        guard !eqCurveDB.isEmpty else { return 0 }
        let flat = Array(repeating: 0.0, count: eqCurveDB.count)
        let adj = findOffset(magnitudesDB: flat, frequenciesHz: frequenciesHz, targetPhon: targetPhon)
            - findOffset(magnitudesDB: eqCurveDB, frequenciesHz: frequenciesHz, targetPhon: targetPhon)
        return min(30, max(-30, adj))
    }

    /// Offset (dB) to add to `magnitudesDB` so ISO loudness equals `targetPhon`.
    public static func findOffset(
        magnitudesDB: [Double],
        frequenciesHz: [Double],
        targetPhon: Double
    ) -> Double {
        let par = normalizeParams(for: frequenciesHz)
        var x = 0.0
        var dx = 0.0
        let l10 = log(10.0) / 10.0
        repeat {
            var v = 0.0
            var d = 0.0
            for (i, p) in par.enumerated() {
                let fr = magnitudesDB[i]
                let v0 = exp(l10 * (fr + x - p.freeField))
                var ds = l10 * v0
                let v1 = p.k + pow(v0, p.a)
                ds *= p.a * pow(v0, p.a - 1)
                v += p.c * pow(v1, 4)
                ds *= p.c * 4 * pow(v1, 3)
                d += ds
            }
            guard v > 0, d != 0 else { break }
            dx = (log(v) - targetPhon * l10) * (v / d)
            x -= dx
        } while abs(dx) > 0.01
        return x
    }

    private struct BandParam {
        var a: Double
        var k: Double
        var c: Double
        var freeField: Double
    }

    private static func normalizeParams(for frequenciesHz: [Double]) -> [BandParam] {
        let pF = isoF
        let pA = isoAf
        let pLU = isoLU
        let pTf = isoTf
        var i = 0
        return frequenciesHz.map { f in
            while i < pF.count, f >= pF[i] { i += 1 }
            let i0 = max(0, i - 1)
            let i1 = min(i, pF.count - 1)
            let g: (Int) -> Double
            if i0 == i1 {
                g = { idx in
                    switch idx {
                    case 0: return pA[i0]
                    case 1: return pLU[i0]
                    default: return pTf[i0]
                    }
                }
            } else {
                let ll0 = log(pF[i0])
                let ll1 = log(pF[i1])
                let ll = log(f)
                let l = (ll - ll0) / (ll1 - ll0)
                g = { idx in
                    let v: [Double]
                    switch idx {
                    case 0: v = pA
                    case 1: v = pLU
                    default: v = pTf
                    }
                    return v[i0] + l * (v[i1] - v[i0])
                }
            }
            let a = g(0)
            let m = a * (log10(4) - 10 + g(1) / 10)
            let k = (0.005076 / pow(10, m)) - pow(10, a * g(2) / 10)
            let c = pow(10, 9.4 + 4 * m) / Double(frequenciesHz.count)
            let ffi = Int((0.5 + 48 * log2(f / 19.4806)).rounded(.down))
            let ff = freeField[max(0, min(freeField.count - 1, ffi))]
            return BandParam(a: a, k: k, c: c, freeField: ff)
        }
    }

    private static let isoF: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100,
        125, 160, 200, 250, 315, 400, 500, 630,
        800, 1000, 1250, 1600, 2000, 2500, 3150, 4000,
        5000, 6300, 8000, 10000, 12500,
    ]

    private static let isoAf: [Double] = [
        0.532, 0.506, 0.48, 0.455, 0.432, 0.409, 0.387, 0.367,
        0.349, 0.33, 0.315, 0.301, 0.288, 0.276, 0.267, 0.259,
        0.253, 0.25, 0.246, 0.244, 0.243, 0.243, 0.243, 0.242,
        0.242, 0.245, 0.254, 0.271, 0.301,
    ]

    private static let isoLU: [Double] = [
        -31.6, -27.2, -23, -19.1, -15.9, -13, -10.3, -8.1,
        -6.2, -4.5, -3.1, -2, -1.1, -0.4, 0, 0.3,
        0.5, 0, -2.7, -4.1, -1, 1.7, 2.5, 1.2,
        -2.1, -7.1, -11.2, -10.7, -3.1,
    ]

    private static let isoTf: [Double] = [
        78.5, 68.7, 59.5, 51.1, 44, 37.5, 31.5, 26.5,
        22.1, 17.9, 14.4, 11.4, 8.6, 6.2, 4.4, 3,
        2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6, -5.4,
        -1.5, 6, 12.6, 13.9, 12.3,
    ]

    private static let freeField: [Double] = [
        -7, -7, -7, -7, -7, -7, -7, -7, -7, -7,
        -7, -7, -7, -7, -7, -7, -7, -7, -7, -7,
        -7, -6.9275, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9104,
        -7, -7, -7, -7, -7, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9033, -7, -7, -7, -7,
        -7, -7, -7, -6.9114, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9344, -7, -7, -7, -7, -7, -6.976, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.955, -7, -7, -7,
        -7, -7, -7, -6.971, -6.9, -6.9, -6.9, -6.9, -6.9, -6.9,
        -6.9, -6.9, -6.9, -6.9, -6.9, -6.9, -6.8476, -6.8, -6.8, -6.7614,
        -6.6605, -6.6, -6.563, -6.5, -6.4713, -6.3775, -6.3, -6.2937, -6.2038, -6.2,
        -6.1059, -6.1, -6.0137, -6, -5.9271, -5.9, -5.8456, -5.8, -5.7496, -5.7,
        -5.7, -5.7, -5.7, -5.6837, -5.6, -5.6, -5.6, -5.6, -5.5983, -5.5154,
        -5.5, -5.5, -5.4252, -5.4, -5.4, -5.347, -5.3, -5.3, -5.2513, -5.2,
        -5.1659, -5.1, -5.1, -5.0771, -5, -5, -5, -4.9, -4.9, -4.8103,
        -4.8, -4.8, -4.7326, -4.7, -4.7, -4.6433, -4.6, -4.6, -4.5554, -4.5,
        -4.4738, -4.4, -4.3766, -4.2851, -4.2, -4.1962, -4.0989, -4.0031, -3.9087, -3.8155,
        -3.7238, -3.6243, -3.5351, -3.4383, -3.343, -3.249, -3.2, -3.1568, -3.0668, -3,
        -3, -3, -2.9879, -2.9, -2.9, -2.9, -2.9921, -3, -3, -3,
        -3, -3.0666, -3.1, -3.1, -3.1, -3.1459, -3.2, -3.2, -3.232, -3.3,
        -3.3239, -3.4, -3.4, -3.4073, -3.5, -3.5, -3.5, -3.5, -3.5, -3.4239,
        -3.4, -3.4, -3.3396, -3.3, -3.2486, -3.2, -3.2, -3.1651, -3.1, -3.0782,
        -2.9801, -2.8877, -2.7924, -2.6984, -2.6015, -2.3184, -1.9485, -1.5778, -1.1964, -0.8903,
        -0.5344, -0.1539, 0.3316, 0.9083, 1.4305, 1.9369, 2.5105, 3.0759, 3.6024, 4.0027,
        4.4847, 5.0482, 5.5152, 5.8994, 6.2776, 6.7381, 7.1303, 7.5168, 7.8858, 8.273,
        8.6547, 8.9731, 9.2596, 9.542, 9.7857, 10.0111, 10.2325, 10.3532, 10.522, 10.6,
        10.6, 10.6, 10.6, 10.5044, 10.41, 10.3145, 10.2205, 10.1255, 10.0318, 9.9373,
        9.784, 9.6459, 9.4536, 9.2578, 9.1234, 8.967, 8.8736, 8.7552, 8.566, 8.3879,
        8.2881, 8.0958, 7.9064, 7.8099, 7.6287, 7.5201, 7.3477, 7.2307, 7.0709, 6.9399,
        6.7916, 6.6514, 6.5552, 6.4604, 6.367, 6.2718, 6.1766, 6.0812, 5.9743, 5.7916,
        5.6975, 5.602, 5.5078, 5.3247, 5.0547, 4.7686, 4.4154, 4.1009, 3.9385, 3.7344,
        3.3998, 3.0163, 2.6382, 2.2957, 1.9799, 1.6248, 1.3404, 1.0424, 0.674, 0.3851,
        0.0061, -0.4693, -0.8516, -1.2304, -1.5338, -1.8916, -2.2698, -2.6502, -3.029, -3.3545,
        -3.5925, -3.8657, -4.2083, -4.4624, -4.6516, -4.8415, -5.0151, -5.0893, -5, -5,
        -5, -4.9106, -4.8156, -4.7213, -4.626, -4.3943, -4.1735, -3.9839, -3.7943, -3.6046,
        -3.4149, -3.1878, -2.9033, -2.646, -2.4349, -2.1491, -1.8541, -1.4741, -1.0959, -0.8119,
        -0.4357, -0.1439, 0.1418, 0.4251, 0.7093, 1.0593, 1.3192, 1.4541, 1.5493, 1.6437,
        1.7, 1.7336, 1.8, 1.8, 1.8, 1.8, 1.7926, 1.7, 1.7, 1.6079,
        1.5133, 1.5, 1.4237, 1.1863, 0.968, 0.7786, 0.4219, -0.052, -0.5701, -1.1788,
        -1.8437, -2.5366, -3.2958, -4.1103, -5.0995, -5.7632, -6.4349, -7.2856, -7.8593, -9.9,
    ]
}
