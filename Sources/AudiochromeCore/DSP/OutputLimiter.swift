import Foundation

/// Last stage before the device. Keeps sample peaks at 0 dBFS so the DAC
/// does not hard-clip (which would add odd harmonics the sliders did not ask for).
/// Instant attack, stereo-linked; only reduces gain when a peak is over ceiling.
/// Audio-thread process does not allocate.
final class OutputLimiter: @unchecked Sendable {
    private static let ceiling = 1.0
    private static let releaseSeconds = 0.100

    private let lock = NSLock()
    private var pendingRate: Double?
    private var sampleRate = 48_000.0
    private var releaseCoeff = 1.0 - exp(-1.0 / (0.100 * 48_000.0))
    private var env = 0.0

    func update(sampleRate: Double) {
        lock.lock()
        pendingRate = max(sampleRate, 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        pendingRate = nil
        lock.unlock()
        sampleRate = 0
        releaseCoeff = 0
        env = 0
    }

    func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        adoptPendingIfNeeded()
        guard frames > 0 else { return }
        for i in 0..<frames {
            let gain = advance(peak: max(abs(Double(left[i])), abs(Double(right[i]))))
            if gain < 1 {
                left[i] = Float(Double(left[i]) * gain)
                right[i] = Float(Double(right[i]) * gain)
            }
        }
    }

    func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        adoptPendingIfNeeded()
        guard frames > 0, channels > 0 else { return }
        for i in 0..<frames {
            let base = i * channels
            var peak = 0.0
            for c in 0..<channels {
                peak = max(peak, abs(Double(buffer[base + c])))
            }
            let gain = advance(peak: peak)
            if gain < 1 {
                for c in 0..<channels {
                    buffer[base + c] = Float(Double(buffer[base + c]) * gain)
                }
            }
        }
    }

    func processMono(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        adoptPendingIfNeeded()
        guard frames > 0 else { return }
        for i in 0..<frames {
            let gain = advance(peak: abs(Double(buffer[i])))
            if gain < 1 {
                buffer[i] = Float(Double(buffer[i]) * gain)
            }
        }
    }

    private func advance(peak: Double) -> Double {
        if peak > env {
            env = peak
        } else {
            env += releaseCoeff * (peak - env)
        }
        return env > Self.ceiling ? Self.ceiling / env : 1
    }

    private func adoptPendingIfNeeded() {
        lock.lock()
        let next = pendingRate
        pendingRate = nil
        lock.unlock()

        guard let next, abs(next - sampleRate) > 0.5 else { return }
        sampleRate = next
        releaseCoeff = 1.0 - exp(-1.0 / (Self.releaseSeconds * next))
        env = 0
    }
}
