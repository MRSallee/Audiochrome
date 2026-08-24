import Darwin
import Foundation

/// Mid-only saturation. The sliders are the effect.
/// Even = DC-blocked \(x^{2}\) (2nd harmonic). Odd = unity-gain soft clip.
/// Bandwidth = which band hits those curves; the rest is dry.
/// 8× oversample is anti-alias only. Audio-thread process does not allocate.
final class SaturationProcessor: @unchecked Sendable {
    private enum BandMode: Int {
        case bass = 0
        case edges = 1
        case full = 2
    }

    private struct BiquadCoeffs: Equatable {
        var b0 = 0.0
        var b1 = 0.0
        var b2 = 0.0
        var a1 = 0.0
        var a2 = 0.0
    }

    private struct Params: Equatable {
        var enabled = false
        var evenAmt = 0.0
        var oddAmt = 0.0
        var memAmt = 0.0
        var memDepth = 0.0
        var memCoeff = 0.0
        var dcR8 = 0.0
        var os0 = BiquadCoeffs()
        var os1 = BiquadCoeffs()
        var os2 = BiquadCoeffs()
        var os3 = BiquadCoeffs()
        var bass0 = BiquadCoeffs()
        var air0 = BiquadCoeffs()
        var band = BandMode.bass
        var sampleRate = 0.0

        static let bypassed = Params()
    }

    private static let oddDrive = 1.55
    private static let dcBlockHz = 25.0
    private static let osFactor = 8
    /// Pass 20 kHz (H2 of 10 kHz at 48 k); kill 30 kHz+ before decimate.
    private static let osCutoffRatio = 0.90
    private static let osQ = (
        0.509795579,
        0.601344887,
        0.899976223,
        2.562915447
    )
    /// 2-pole Butterworth.
    private static let butter2Q = 0.707106781

    private let lock = NSLock()
    private var pending: Params?
    private var params = Params.bypassed

    private var evenState = ShaperState()
    private var airEvenState = ShaperState()
    private var osUp = Cascade4()
    private var osDown = Cascade4()
    private var bassLP = BiquadState()
    private var airHP = BiquadState()

    init() {}

    func update(settings: SaturationSettings, sampleRate: Double) {
        let rate = max(sampleRate, 1)
        var next = Params.bypassed
        if EffectsFeature.isEnabled, settings.enabled {
            next.enabled = true
            next.evenAmt = settings.even.evenMix
            next.oddAmt = settings.odd.oddMix
            next.memAmt = settings.memory == .off ? 0 : 1
            next.memDepth = settings.memory.depth
            if settings.memory.seconds > 0 {
                next.memCoeff = 1.0 - exp(-1.0 / (settings.memory.seconds * rate))
            }
            let osRate = Double(Self.osFactor) * rate
            next.dcR8 = exp(-2.0 * Double.pi * Self.dcBlockHz / osRate)
            let osCutoff = Self.osCutoffRatio * (rate * 0.5)
            next.os0 = Self.lowpassCoeffs(cutoffHz: osCutoff, sampleRate: osRate, q: Self.osQ.0)
            next.os1 = Self.lowpassCoeffs(cutoffHz: osCutoff, sampleRate: osRate, q: Self.osQ.1)
            next.os2 = Self.lowpassCoeffs(cutoffHz: osCutoff, sampleRate: osRate, q: Self.osQ.2)
            next.os3 = Self.lowpassCoeffs(cutoffHz: osCutoff, sampleRate: osRate, q: Self.osQ.3)
            next.bass0 = Self.lowpassCoeffs(
                cutoffHz: settings.bandwidth.bassHz,
                sampleRate: osRate,
                q: Self.butter2Q
            )
            next.air0 = Self.highpassCoeffs(
                cutoffHz: settings.bandwidth.airHz,
                sampleRate: osRate,
                q: Self.butter2Q
            )
            switch settings.bandwidth {
            case .bass: next.band = .bass
            case .edges: next.band = .edges
            case .full: next.band = .full
            }
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
        let mid = 0.5 * (left + right)
        let side = 0.5 * (left - right)
        let wet = processMid(mid)
        left = wet + side
        right = wet - side
    }

    private func processMid(_ x: Double) -> Double {
        let sag = memorySag(x, state: &evenState)
        var out = 0.0
        let n = Self.osFactor
        for i in 0..<n {
            let stuffed = i == 0 ? x * Double(n) : 0.0
            let upsampled = osUp.process(stuffed, params.os0, params.os1, params.os2, params.os3)
            let shaped = shapeBand(upsampled, sag: sag)
            let filtered = osDown.process(shaped, params.os0, params.os1, params.os2, params.os3)
            if i == n - 1 {
                out = filtered
            }
        }
        return out
    }

    /// Split after upsample so dry and wet share the same OS delay.
    /// Mixing a delayed air band with an undelayed mid was cancelling ~8 kHz.
    private func shapeBand(_ x: Double, sag: Double) -> Double {
        switch params.band {
        case .full:
            return shapeOS(x, sag: sag, evenState: &evenState)
        case .bass:
            let bass = bassLP.process(x, params.bass0)
            return shapeOS(bass, sag: sag, evenState: &evenState) + (x - bass)
        case .edges:
            let bass = bassLP.process(x, params.bass0)
            let air = airHP.process(x, params.air0)
            let bassOut = shapeOS(bass, sag: sag, evenState: &evenState)
            let airOut = shapeOS(air, sag: sag, evenState: &airEvenState)
            return bassOut + (x - bass - air) + airOut
        }
    }

    private func shapeOS(
        _ x: Double,
        sag: Double,
        evenState: inout ShaperState
    ) -> Double {
        var y = x
        if params.evenAmt > 0 {
            y += evenAdd(x, gain: params.evenAmt * sag, dcR: params.dcR8, state: &evenState)
        }
        if params.oddAmt > 0 {
            y = oddSoft(y, sag: sag)
        }
        return y
    }

    /// \(x^{2}\) minus DC. A sine becomes only a 2nd harmonic.
    private func evenAdd(_ x: Double, gain: Double, dcR: Double, state: inout ShaperState) -> Double {
        let raw = x * x
        let blocked = raw - state.dcX + dcR * state.dcY
        state.dcX = raw
        state.dcY = blocked
        return gain * blocked
    }

    private func oddSoft(_ x: Double, sag: Double) -> Double {
        let k = Self.oddDrive * sag
        let soft = tanh(k * x) / k
        return x + params.oddAmt * (soft - x)
    }

    private func memorySag(_ x: Double, state: inout ShaperState) -> Double {
        guard params.memAmt > 0 else { return 1 }
        state.env += params.memCoeff * (abs(x) - state.env)
        return 1.0 + params.memDepth * state.env
    }

    private static func lowpassCoeffs(cutoffHz: Double, sampleRate: Double, q: Double) -> BiquadCoeffs {
        let nyquist = sampleRate * 0.45
        let freq = min(max(cutoffHz, 10), nyquist)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2.0 * max(q, 0.05))
        let a0 = 1.0 + alpha
        let oneMinusCos = 1.0 - cosw
        return BiquadCoeffs(
            b0: oneMinusCos * 0.5 / a0,
            b1: oneMinusCos / a0,
            b2: oneMinusCos * 0.5 / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private static func highpassCoeffs(cutoffHz: Double, sampleRate: Double, q: Double) -> BiquadCoeffs {
        let nyquist = sampleRate * 0.45
        let freq = min(max(cutoffHz, 10), nyquist)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / (2.0 * max(q, 0.05))
        let a0 = 1.0 + alpha
        let onePlusCos = 1.0 + cosw
        return BiquadCoeffs(
            b0: onePlusCos * 0.5 / a0,
            b1: -onePlusCos / a0,
            b2: onePlusCos * 0.5 / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    private func adoptPendingIfNeeded() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != params else { return }
        let rateChanged = abs(next.sampleRate - params.sampleRate) > 0.5
        let turningOn = next.enabled && !params.enabled
        let bandChanged = next.band != params.band
        params = next
        if !next.enabled || rateChanged || turningOn || bandChanged {
            resetMemory()
        }
    }

    private func resetMemory() {
        evenState = ShaperState()
        airEvenState = ShaperState()
        osUp = Cascade4()
        osDown = Cascade4()
        bassLP = BiquadState()
        airHP = BiquadState()
    }

    private struct ShaperState {
        var dcX = 0.0
        var dcY = 0.0
        var env = 0.0
    }

    private struct BiquadState {
        var z1 = 0.0
        var z2 = 0.0

        mutating func process(_ x: Double, _ c: BiquadCoeffs) -> Double {
            let y = c.b0 * x + z1
            z1 = c.b1 * x - c.a1 * y + z2
            z2 = c.b2 * x - c.a2 * y
            return y
        }
    }

    private struct Cascade4 {
        var s0 = BiquadState()
        var s1 = BiquadState()
        var s2 = BiquadState()
        var s3 = BiquadState()

        mutating func process(
            _ x: Double,
            _ c0: BiquadCoeffs,
            _ c1: BiquadCoeffs,
            _ c2: BiquadCoeffs,
            _ c3: BiquadCoeffs
        ) -> Double {
            let y0 = s0.process(x, c0)
            let y1 = s1.process(y0, c1)
            let y2 = s2.process(y1, c2)
            return s3.process(y2, c3)
        }
    }
}
