import Foundation

/// Octave-down: time rising zeros, emit a sine at f/2, add it.
/// Dry is never scaled. Intervals outside 25–80 Hz are ignored.
/// Audio-thread process does not allocate.
final class SubharmonicProcessor: @unchecked Sendable {
    private static let twoPi = Double.pi * 2
    private static let lookaheadSeconds = 0.040
    /// Equal-power blend between delay taps when Timing Lock flips.
    private static let spliceSeconds = 0.012
    private static let maxDelay = 16_384
    private static let dcBlockHz = 10.0

    private struct Params: Equatable {
        var enabled = false
        var extractCoeff = 0.0
        var subCoeff = 0.0
        var hpCoeff = 0.0
        var attackCoeff = 0.0
        var releaseCoeff = 0.0
        var minPeriodSamples = 0.0
        var maxPeriodSamples = 0.0
        var delaySamples = 0
        var mix = 0.0
        var sampleRate = 0.0

        static let bypassed = Params()
    }

    private let lock = NSLock()
    private var pending: Params?
    private var params = Params.bypassed

    private var extract1 = 0.0
    private var extract2 = 0.0
    private var extractHPX = 0.0
    private var extractHPY = 0.0
    private var subLP = 0.0
    private var env = 0.0
    private var prevBass = 0.0
    private var samplesSinceCrossing = 1_000_000.0
    private var lastPeriod = 0.0
    private var phase = 0.0
    private var activeDelaySamples = 0
    private var spliceFrom = 0
    private var spliceTo = 0
    private var splicePos = 0
    private var spliceLen = 0
    private var queuedDelay: Int?
    private var warmupTarget = 0
    private var warmupFilled = 0
    /// Keep the delay running after disable until it has spliced back to zero.
    private var running = false
    private var lastRate = 48_000.0

    private var delayL: [Double]
    private var delayR: [Double]
    private var writeIndex = 0

    init() {
        delayL = [Double](repeating: 0, count: Self.maxDelay)
        delayR = [Double](repeating: 0, count: Self.maxDelay)
    }

    func update(settings: SubharmonicSettings, sampleRate: Double) {
        let rate = max(sampleRate, 1)
        var next = Params.bypassed
        if settings.enabled {
            next.enabled = true
            next.extractCoeff = 1.0 - exp(-2.0 * Double.pi * settings.range.extractHz / rate)
            next.subCoeff = 1.0 - exp(-2.0 * Double.pi * settings.range.subLowpassHz / rate)
            next.hpCoeff = exp(-2.0 * Double.pi * Self.dcBlockHz / rate)
            next.attackCoeff = 1.0 - exp(-1.0 / (0.008 * rate))
            next.releaseCoeff = 1.0 - exp(-1.0 / (0.080 * rate))
            next.minPeriodSamples = rate / 80
            next.maxPeriodSamples = rate / 25
            if settings.lookahead {
                next.delaySamples = min(Self.maxDelay - 1, max(0, Int((Self.lookaheadSeconds * rate).rounded())))
            }
            next.mix = settings.outputMuted ? 0 : settings.amount.mix
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
        guard running, frames > 0 else { return }
        for i in 0..<frames {
            let pair = processPair(left: Double(left[i]), right: Double(right[i]))
            left[i] = Float(pair.left)
            right[i] = Float(pair.right)
        }
    }

    func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        adoptPendingIfNeeded()
        guard running, frames > 0, channels >= 2 else { return }
        for i in 0..<frames {
            let base = i * channels
            let pair = processPair(left: Double(buffer[base]), right: Double(buffer[base + 1]))
            buffer[base] = Float(pair.left)
            buffer[base + 1] = Float(pair.right)
        }
    }

    private func processPair(left: Double, right: Double) -> (left: Double, right: Double) {
        let bass = extract(mid: (left + right) * 0.5)
        samplesSinceCrossing += 1
        let hyst = max(0.0004, env * 0.06)
        if prevBass <= hyst, bass > hyst {
            let interval = samplesSinceCrossing
            if interval >= params.minPeriodSamples, interval <= params.maxPeriodSamples {
                lastPeriod = interval
            }
            samplesSinceCrossing = 0
        }
        prevBass = bass

        let level = abs(bass)
        if level > env {
            env += params.attackCoeff * (level - env)
        } else {
            env += params.releaseCoeff * (level - env)
        }

        delayL[writeIndex] = left
        delayR[writeIndex] = right
        if warmupTarget > 0 {
            warmupFilled += 1
            if warmupFilled >= warmupTarget {
                let target = warmupTarget
                warmupTarget = 0
                beginSplice(to: target)
            }
        }
        let dry = readDry()
        writeIndex = (writeIndex + 1) % Self.maxDelay

        var raw = 0.0
        if lastPeriod > 1 {
            phase += Double.pi / lastPeriod
            if phase > Self.twoPi {
                phase -= Self.twoPi
            }
            raw = sin(phase) * env
        }
        subLP += params.subCoeff * (raw - subLP)
        let wet = subLP * params.mix
        return (dry.left + wet, dry.right + wet)
    }

    /// Equal-power mix of the old and new delay taps so Timing Lock
    /// doesn’t mute or step the dry.
    private func readDry() -> (left: Double, right: Double) {
        if spliceLen > 0 {
            let t = min(1, Double(splicePos) / Double(spliceLen))
            let wTo = sin(t * Double.pi * 0.5)
            let wFrom = cos(t * Double.pi * 0.5)
            let left = tap(delayL, samples: spliceFrom) * wFrom + tap(delayL, samples: spliceTo) * wTo
            let right = tap(delayR, samples: spliceFrom) * wFrom + tap(delayR, samples: spliceTo) * wTo
            splicePos += 1
            if splicePos >= spliceLen {
                finishSplice()
            }
            return (left, right)
        }
        return (tap(delayL, samples: activeDelaySamples), tap(delayR, samples: activeDelaySamples))
    }

    private func tap(_ line: [Double], samples: Int) -> Double {
        let readIndex = (writeIndex - samples + Self.maxDelay) % Self.maxDelay
        return line[readIndex]
    }

    private func beginSplice(to target: Int) {
        guard target != activeDelaySamples else { return }
        spliceFrom = activeDelaySamples
        spliceTo = target
        splicePos = 0
        spliceLen = max(1, Int((Self.spliceSeconds * lastRate).rounded()))
    }

    private func requestDelay(_ target: Int) {
        if spliceLen > 0 {
            queuedDelay = target
            return
        }
        if target == activeDelaySamples {
            if !params.enabled {
                running = false
                resetMemory()
            }
            return
        }
        beginSplice(to: target)
    }

    private func finishSplice() {
        activeDelaySamples = spliceTo
        spliceLen = 0
        if let queued = queuedDelay {
            queuedDelay = nil
            beginSplice(to: queued)
            return
        }
        if !params.enabled, activeDelaySamples == 0 {
            running = false
            resetMemory()
        }
    }

    private func extract(mid: Double) -> Double {
        let hp = mid - extractHPX + params.hpCoeff * extractHPY
        extractHPX = mid
        extractHPY = hp
        let a = params.extractCoeff
        extract1 += a * (hp - extract1)
        extract2 += a * (extract1 - extract2)
        return extract2
    }

    private func adoptPendingIfNeeded() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != params else { return }
        let wasEnabled = params.enabled
        if next.sampleRate > 1 {
            lastRate = next.sampleRate
        }
        let rateChanged = next.sampleRate > 1 && abs(next.sampleRate - params.sampleRate) > 0.5 && wasEnabled

        if next.enabled {
            params = next
            if !wasEnabled || rateChanged {
                resetMemory()
                running = true
                if next.delaySamples > 0 {
                    warmupTarget = next.delaySamples
                    warmupFilled = 0
                }
            } else if next.delaySamples == 0 {
                warmupTarget = 0
                requestDelay(0)
            } else if warmupTarget > 0 {
                warmupTarget = next.delaySamples
            } else {
                requestDelay(next.delaySamples)
            }
        } else {
            params = next
            warmupTarget = 0
            requestDelay(0)
        }
    }

    private func resetMemory() {
        extract1 = 0
        extract2 = 0
        extractHPX = 0
        extractHPY = 0
        subLP = 0
        env = 0
        prevBass = 0
        samplesSinceCrossing = 1_000_000
        lastPeriod = 0
        phase = 0
        activeDelaySamples = 0
        spliceFrom = 0
        spliceTo = 0
        splicePos = 0
        spliceLen = 0
        queuedDelay = nil
        warmupTarget = 0
        warmupFilled = 0
        writeIndex = 0
        for i in delayL.indices { delayL[i] = 0 }
        for i in delayR.indices { delayR[i] = 0 }
    }
}
