import Foundation

/// Classic octave-down subharmonic synth (zero-crossing divider), mid-only.
///
/// Extract the bass from (L+R)/2, toggle a square on each rising zero,
/// amplitude-follow it, lowpass, then add equally to both ears.
/// Audio-thread process does not allocate.
final class SubharmonicProcessor: @unchecked Sendable {
    private struct Params: Equatable {
        var enabled = false
        var extractCoeff = 0.0
        var subCoeff = 0.0
        var attackCoeff = 0.0
        var releaseCoeff = 0.0
        var mix = 0.0
        var sampleRate = 0.0

        static let bypassed = Params()
    }

    private let lock = NSLock()
    private var pending: Params?
    private var params = Params.bypassed

    private var extractLP = 0.0
    private var extractHPX = 0.0
    private var extractHPY = 0.0
    private var subLP = 0.0
    private var env = 0.0
    private var prevExtract = 0.0
    private var highSide = false
    private var squarePositive = false

    func update(settings: SubharmonicSettings, sampleRate: Double) {
        let rate = max(sampleRate, 1)
        var next = Params.bypassed
        if EffectsFeature.isEnabled, settings.enabled {
            next.enabled = true
            next.extractCoeff = 1.0 - exp(-2.0 * Double.pi * settings.range.extractHz / rate)
            next.subCoeff = 1.0 - exp(-2.0 * Double.pi * settings.range.subLowpassHz / rate)
            next.attackCoeff = 1.0 - exp(-1.0 / (0.004 * rate))
            next.releaseCoeff = 1.0 - exp(-1.0 / (0.070 * rate))
            next.mix = settings.amount.mix
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
            let wet = synthesize(mid: (Double(left[i]) + Double(right[i])) * 0.5)
            left[i] += Float(wet)
            right[i] += Float(wet)
        }
    }

    /// Audio-thread only. Extra channels are left untouched.
    func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        adoptPendingIfNeeded()
        guard params.enabled, frames > 0, channels >= 2 else { return }
        for i in 0..<frames {
            let base = i * channels
            let wet = synthesize(mid: (Double(buffer[base]) + Double(buffer[base + 1])) * 0.5)
            buffer[base] += Float(wet)
            buffer[base + 1] += Float(wet)
        }
    }

    private func synthesize(mid: Double) -> Double {
        // DC-block then one-pole LPF — the divider should only see bass.
        let hp = mid - extractHPX + 0.995 * extractHPY
        extractHPX = mid
        extractHPY = hp
        extractLP += params.extractCoeff * (hp - extractLP)

        let level = abs(extractLP)
        if level > env {
            env += params.attackCoeff * (level - env)
        } else {
            env += params.releaseCoeff * (level - env)
        }

        let hyst = max(0.0012, env * 0.06)
        if !highSide, extractLP > hyst, prevExtract <= hyst {
            squarePositive.toggle()
            highSide = true
        } else if highSide, extractLP < -hyst {
            highSide = false
        }
        prevExtract = extractLP

        let raw = (squarePositive ? 1.0 : -1.0) * env
        subLP += params.subCoeff * (raw - subLP)
        let shaped = tanh(subLP * 1.6)
        return shaped * params.mix
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
        extractLP = 0
        extractHPX = 0
        extractHPY = 0
        subLP = 0
        env = 0
        prevExtract = 0
        highSide = false
        squarePositive = false
    }
}
