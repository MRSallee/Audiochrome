import Foundation

/// Frequency-dependent Bauer / Linkwitz crossfeed.
///
///   yL = xL + g * (lp(delay(xR)) - lp(xL))
///   g  = bleed.mix   (UI 100% → g = 0.5, mono bass)
///
/// Range sets the one-pole cutoff. Image is ITD on the cross path only.
/// Audio-thread process does not allocate. Parameter swaps are lock + adopt.
final class CrossfeedProcessor: @unchecked Sendable {
    private struct Params: Equatable {
        var enabled = false
        var lpfCoeff = 0.0
        var mix = 0.0
        var delaySamples = 0.0
        var sampleRate = 0.0

        static let bypassed = Params()
    }

    private static let maxDelaySamples = 256

    private let lock = NSLock()
    private var pending: Params?
    private var params = Params.bypassed
    private var lpOwnL = 0.0
    private var lpOwnR = 0.0
    private var lpCrossL = 0.0
    private var lpCrossR = 0.0
    private var delayL: [Double]
    private var delayR: [Double]
    private var writeIndex = 0

    init() {
        delayL = [Double](repeating: 0, count: Self.maxDelaySamples)
        delayR = [Double](repeating: 0, count: Self.maxDelaySamples)
    }

    func update(settings: CrossfeedSettings, sampleRate: Double) {
        let rate = max(sampleRate, 1)
        var next = Params.bypassed
        if settings.enabled {
            next.enabled = true
            next.lpfCoeff = 1.0 - exp(-2.0 * Double.pi * settings.range.cutoffHz / rate)
            next.mix = settings.bleed.mix
            next.delaySamples = settings.image.delayMicroseconds * 1e-6 * rate
            next.sampleRate = rate
        }

        lock.lock()
        pending = next
        lock.unlock()
    }

    func clear() {
        lock.lock()
        pending = .bypassed
        lock.unlock()
    }

    /// Audio-thread only.
    func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        adoptPendingIfNeeded()
        guard params.enabled, frames > 0 else { return }
        for i in 0..<frames {
            var l = Double(left[i])
            var r = Double(right[i])
            processPair(&l, &r)
            left[i] = Float(l)
            right[i] = Float(r)
        }
    }

    /// Audio-thread only. Extra channels are left untouched.
    func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        adoptPendingIfNeeded()
        guard params.enabled, frames > 0, channels >= 2 else { return }
        for i in 0..<frames {
            let base = i * channels
            var l = Double(buffer[base])
            var r = Double(buffer[base + 1])
            processPair(&l, &r)
            buffer[base] = Float(l)
            buffer[base + 1] = Float(r)
        }
    }

    private func processPair(_ left: inout Double, _ right: inout Double) {
        writeDelay(left, into: &delayL)
        writeDelay(right, into: &delayR)
        let delayedR = readDelay(delayR, samples: params.delaySamples)
        let delayedL = readDelay(delayL, samples: params.delaySamples)
        writeIndex = (writeIndex + 1) % Self.maxDelaySamples

        lpOwnL += params.lpfCoeff * (left - lpOwnL)
        lpOwnR += params.lpfCoeff * (right - lpOwnR)
        lpCrossR += params.lpfCoeff * (delayedR - lpCrossR)
        lpCrossL += params.lpfCoeff * (delayedL - lpCrossL)

        left += params.mix * (lpCrossR - lpOwnL)
        right += params.mix * (lpCrossL - lpOwnR)
    }

    private func writeDelay(_ sample: Double, into line: inout [Double]) {
        line[writeIndex] = sample
    }

    private func readDelay(_ line: [Double], samples: Double) -> Double {
        let clamped = min(max(samples, 0), Double(Self.maxDelaySamples - 2))
        let whole = Int(clamped)
        let frac = clamped - Double(whole)
        let i0 = (writeIndex - whole + Self.maxDelaySamples * 4) % Self.maxDelaySamples
        let i1 = (i0 - 1 + Self.maxDelaySamples) % Self.maxDelaySamples
        return line[i0] * (1 - frac) + line[i1] * frac
    }

    private func adoptPendingIfNeeded() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != params else { return }
        let rateChanged = abs(next.sampleRate - params.sampleRate) > 0.5
        let turningOn = next.enabled && !params.enabled
        params = next
        if !next.enabled || rateChanged || turningOn {
            resetMemory()
        }
    }

    private func resetMemory() {
        lpOwnL = 0
        lpOwnR = 0
        lpCrossL = 0
        lpCrossR = 0
        for i in delayL.indices { delayL[i] = 0 }
        for i in delayR.indices { delayR[i] = 0 }
        writeIndex = 0
    }
}
