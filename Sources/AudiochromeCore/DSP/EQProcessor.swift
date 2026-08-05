import Foundation

/// Second-order IIR (RBJ Audio EQ Cookbook). Coefficients kept in double; process in double.
struct Biquad: Sendable {
    var b0 = 1.0
    var b1 = 0.0
    var b2 = 0.0
    var a1 = 0.0
    var a2 = 0.0
    var z1 = 0.0
    var z2 = 0.0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    func magnitudeDB(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let z1r = cos(w)
        let z1i = -sin(w)
        let z2r = cos(2 * w)
        let z2i = -sin(2 * w)

        let numR = b0 + b1 * z1r + b2 * z2r
        let numI = b1 * z1i + b2 * z2i
        let denR = 1.0 + a1 * z1r + a2 * z2r
        let denI = a1 * z1i + a2 * z2i

        let mag2 = (numR * numR + numI * numI) / max(denR * denR + denI * denI, 1e-30)
        return 10.0 * log10(mag2)
    }

    static func peaking(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.001))
        let cosw0 = cos(w0)

        let b0 = 1 + alpha * A
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / A
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    static func lowShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * max(q, 0.001))
        let twoSqrtAAlpha = 2 * sqrt(A) * alpha

        let b0 = A * ((A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha)
        let b1 = 2 * A * ((A - 1) - (A + 1) * cosw0)
        let b2 = A * ((A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha)
        let a0 = (A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha
        let a1 = -2 * ((A - 1) + (A + 1) * cosw0)
        let a2 = (A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * max(q, 0.001))
        let twoSqrtAAlpha = 2 * sqrt(A) * alpha

        let b0 = A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosw0)
        let b2 = A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha)
        let a0 = (A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha
        let a1 = 2 * ((A - 1) - (A + 1) * cosw0)
        let a2 = (A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    static func from(filter: EQFilter, sampleRate: Double) -> Biquad? {
        guard filter.enabled, filter.frequencyHz > 0, sampleRate > 0 else { return nil }
        let freq = min(filter.frequencyHz, sampleRate * 0.49)
        switch filter.kind {
        case .peaking:
            return .peaking(sampleRate: sampleRate, frequency: freq, gainDB: filter.gainDB, q: filter.q)
        case .lowShelf:
            return .lowShelf(sampleRate: sampleRate, frequency: freq, gainDB: filter.gainDB, q: filter.q)
        case .highShelf:
            return .highShelf(sampleRate: sampleRate, frequency: freq, gainDB: filter.gainDB, q: filter.q)
        case .lowPass, .highPass, .notch, .bandPass, .allPass, .unknown:
            // Unknown must not fall through to peaking — that turns shelves (LSC/HSC) into narrow boosts.
            return nil
        }
    }

    private static func normalized(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
        var f = Biquad()
        f.b0 = b0 / a0
        f.b1 = b1 / a0
        f.b2 = b2 / a0
        f.a1 = a1 / a0
        f.a2 = a2 / a0
        return f
    }
}

/// Real-time EQ processor. Control thread publishes a pending bank; audio thread swaps & owns state.
public final class EQProcessor: @unchecked Sendable {
    private struct Bank {
        var left: [Biquad]
        var right: [Biquad]
        var leftGain: Double
        var rightGain: Double
        var sampleRate: Double
        var signature: String
    }

    /// Only touched by the audio thread after swap (plus brief lock during swap).
    private var current = Bank(left: [], right: [], leftGain: 1, rightGain: 1, sampleRate: 48_000, signature: "")
    private var pending: Bank?
    private var publishedSignature = ""
    private let lock = NSLock()

    public init() {}

    public func update(profile: EQProfile, sampleRate: Double) {
        let rate = max(sampleRate, 1)
        let signature = Self.signature(for: profile, sampleRate: rate)

        lock.lock()
        let already = publishedSignature == signature
        lock.unlock()
        if already { return }

        let lChannel = profile.effectiveLeft
        let rChannel = profile.effectiveRight
        let bank = Bank(
            left: lChannel.filters.compactMap { Biquad.from(filter: $0, sampleRate: rate) },
            right: rChannel.filters.compactMap { Biquad.from(filter: $0, sampleRate: rate) },
            leftGain: pow(10.0, lChannel.preampDB / 20.0),
            rightGain: pow(10.0, rChannel.preampDB / 20.0),
            sampleRate: rate,
            signature: signature
        )

        lock.lock()
        pending = bank
        publishedSignature = signature
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        pending = Bank(left: [], right: [], leftGain: 1, rightGain: 1, sampleRate: current.sampleRate, signature: "clear")
        publishedSignature = "clear"
        lock.unlock()
    }

    public func magnitudeDB(atFrequency frequency: Double, channel: Channel = .left) -> Double {
        // Prefer pending if present, else current — for tests called off audio thread.
        lock.lock()
        let bank = pending ?? current
        lock.unlock()

        let filters = channel == .left ? bank.left : bank.right
        let gain = channel == .left ? bank.leftGain : bank.rightGain
        var total = 20.0 * log10(max(gain, 1e-12))
        for filter in filters {
            total += filter.magnitudeDB(atFrequency: frequency, sampleRate: bank.sampleRate)
        }
        return total
    }

    /// Log-spaced magnitude response (dB) from 20 Hz–20 kHz for UI curve previews.
    public static func frequencyResponseCurve(
        for profile: EQProfile,
        sampleRate: Double = 48_000,
        pointCount: Int = 96,
        channel: Channel = .left
    ) -> [Double] {
        let count = max(pointCount, 2)
        let dsp = EQProcessor()
        dsp.update(profile: profile, sampleRate: max(sampleRate, 1))
        let fMin = 20.0
        let fMax = min(20_000.0, sampleRate * 0.49)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let freq = fMin * pow(fMax / fMin, t)
            return dsp.magnitudeDB(atFrequency: freq, channel: channel)
        }
    }

    public enum Channel {
        case left, right
    }

    /// Process interleaved samples in place. Audio-thread only.
    public func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frames: UInt32, channels: UInt32) {
        guard frames > 0, channels > 0 else { return }
        adoptPendingIfNeeded()

        let frameCount = Int(frames)
        let ch = Int(channels)
        let lg = current.leftGain
        let rg = current.rightGain

        for i in 0..<frameCount {
            let base = i * ch
            var leftSample = Double(buffer[base]) * lg
            for idx in current.left.indices {
                leftSample = current.left[idx].process(leftSample)
            }
            buffer[base] = Float(leftSample)

            if ch > 1 {
                var rightSample = Double(buffer[base + 1]) * rg
                for idx in current.right.indices {
                    rightSample = current.right[idx].process(rightSample)
                }
                buffer[base + 1] = Float(rightSample)
                // Extra channels: gain only — never run L/R filter state on them.
                if ch > 2 {
                    for c in 2..<ch {
                        buffer[base + c] = Float(Double(buffer[base + c]) * lg)
                    }
                }
            }
        }
    }

    /// Process one mono (planar) channel in place. Audio-thread only.
    public func processMono(_ buffer: UnsafeMutablePointer<Float>, frames: UInt32, channel: Channel) {
        guard frames > 0 else { return }
        adoptPendingIfNeeded()

        let frameCount = Int(frames)
        let gain = channel == .left ? current.leftGain : current.rightGain

        for i in 0..<frameCount {
            var sample = Double(buffer[i]) * gain
            if channel == .left {
                for idx in current.left.indices {
                    sample = current.left[idx].process(sample)
                }
            } else {
                for idx in current.right.indices {
                    sample = current.right[idx].process(sample)
                }
            }
            buffer[i] = Float(sample)
        }
    }

    private func adoptPendingIfNeeded() {
        lock.lock()
        if let pending {
            current = pending
            self.pending = nil
        }
        lock.unlock()
    }

    private static func signature(for profile: EQProfile, sampleRate: Double) -> String {
        func channelSig(_ c: ChannelEQ) -> String {
            let filters = c.filters.map {
                "\($0.enabled):\($0.kind.rawValue):\($0.frequencyHz):\($0.gainDB):\($0.q)"
            }.joined(separator: "|")
            return "\(c.preampDB);\(filters)"
        }
        return String(format: "%.2f", sampleRate)
            + "#" + channelSig(profile.effectiveLeft)
            + "#" + channelSig(profile.effectiveRight)
    }
}
