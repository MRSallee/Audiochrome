import Accelerate
import Foundation

/// 12 log-spaced centers for the menu-bar FFT star (20 Hz … 20 kHz).
public enum MenuBarSpectrum {
    public static let bandCount = 12
    public static let frequencies: [Float] = [
        20, 40, 80, 160, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 20_000
    ]
}

/// Real-time 12-band analyzer. Feed pre-EQ tap audio; read `levels` from the main thread.
public final class MenuBarSpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = MenuBarSpectrum.bandCount

    private static let fftSize = 2048
    private static let hopSize = 1024
    private static let log2n = vDSP_Length(11)

    private let fftSetup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var write = 0
    private var filled = 0
    private var hop = 0
    private var time: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    /// -1…1 vs this band’s 2 s average (0 = rest).
    private var smooth: [Float]
    private var loHz: [Float]
    private var hiHz: [Float]
    private var history: [Float]
    private var historySums: [Float]
    private var historyCapacity = 96
    private var historyWrite = 0
    private var historyFilled = 0
    private let lock = NSLock()
    private var sampleRate: Double = 48_000
    private static let averageSeconds: Double = 2
    /// Spike height uses this window, not each FFT hop.
    private static let displaySeconds: Double = 0.1

    public init() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP FFT setup failed")
        }
        fftSetup = setup
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: Self.fftSize)
        time = [Float](repeating: 0, count: Self.fftSize)
        realp = [Float](repeating: 0, count: Self.fftSize / 2)
        imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        smooth = [Float](repeating: 0, count: Self.bandCount)
        historyCapacity = 96
        history = [Float](repeating: 0, count: 96 * Self.bandCount)
        historySums = [Float](repeating: 0, count: Self.bandCount)

        let f = MenuBarSpectrum.frequencies
        loHz = [Float](repeating: 0, count: Self.bandCount)
        hiHz = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount {
            loHz[i] = i == 0 ? f[0] / sqrt(2) : sqrt(f[i - 1] * f[i])
            hiHz[i] = i == Self.bandCount - 1 ? f[i] * sqrt(2) : sqrt(f[i] * f[i + 1])
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    public func reset() {
        write = 0
        filled = 0
        hop = 0
        historyWrite = 0
        historyFilled = 0
        for i in 0..<historySums.count { historySums[i] = 0 }
        for i in 0..<history.count { history[i] = 0 }
        lock.lock()
        for i in 0..<smooth.count { smooth[i] = 0 }
        lock.unlock()
    }

    /// Latest 12-band deviation vs a 2 s average, −1…1 (0 = rest / 12 pt). Safe to read from the main thread.
    public var levels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return smooth
    }

    public func ingestMono(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        if sampleRate > 1 { self.sampleRate = sampleRate }
        for i in 0..<count { push(samples[i]) }
    }

    private func push(_ sample: Float) {
        ring[write] = sample
        write += 1
        if write == Self.fftSize { write = 0 }
        if filled < Self.fftSize { filled += 1 }
        hop += 1
        if filled == Self.fftSize, hop >= Self.hopSize {
            hop = 0
            analyze()
        }
    }

    private func analyze() {
        let n = Self.fftSize
        let start = write
        for i in 0..<n {
            time[i] = ring[(start + i) % n] * window[i]
        }

        time.withUnsafeMutableBufferPointer { timePtr in
            realp.withUnsafeMutableBufferPointer { realPtr in
                imagp.withUnsafeMutableBufferPointer { imagPtr in
                    guard let timeBase = timePtr.baseAddress,
                          let realBase = realPtr.baseAddress,
                          let imagBase = imagPtr.baseAddress
                    else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    timeBase.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                }
            }
        }

        let nyquist = Float(sampleRate) * 0.5
        let binHz = Float(sampleRate) / Float(n)
        let lastBin = n / 2 - 1
        ensureHistoryCapacity()

        let hopSeconds = sampleRate > 1 ? Double(Self.hopSize) / sampleRate : 1.0 / 47
        let shortCount = max(4, Int((Self.displaySeconds / hopSeconds).rounded()))

        var next = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let lo = loHz[band]
            let hi = min(hiHz[band], nyquist)
            guard hi > lo, binHz > 0 else { continue }
            let i0 = max(1, Int(lo / binHz))
            let i1 = min(lastBin, Int(ceil(Double(hi / binHz))))
            guard i1 >= i0 else { continue }
            var peak: Float = 0
            for i in i0...i1 { peak = max(peak, magnitudes[i]) }
            let mag = sqrt(max(0, peak))

            let slot = historyWrite * Self.bandCount + band
            if historyFilled == historyCapacity {
                historySums[band] -= history[slot]
            }
            history[slot] = mag
            historySums[band] += mag
        }

        let longCount = historyFilled == historyCapacity ? historyCapacity : historyFilled + 1
        let recentCount = min(shortCount, longCount)
        for band in 0..<Self.bandCount {
            let longAverage = historySums[band] / Float(max(longCount, 1))
            var shortSum: Float = 0
            for step in 0..<recentCount {
                let idx = (historyWrite - step + historyCapacity) % historyCapacity
                shortSum += history[idx * Self.bandCount + band]
            }
            let shortAverage = shortSum / Float(max(recentCount, 1))
            if longAverage < 1e-5, shortAverage < 1e-5 {
                next[band] = 0
            } else {
                let ratio = shortAverage / max(longAverage, 1e-5)
                // 0.25× 2 s average → −1 (6 pt), 1× → 0 (12 pt), 4× → +1 (18 pt)
                next[band] = min(1, max(-1, log2(max(ratio, 1e-6)) / 2))
            }
        }
        historyWrite += 1
        if historyWrite == historyCapacity { historyWrite = 0 }
        if historyFilled < historyCapacity { historyFilled += 1 }

        lock.lock()
        for band in 0..<Self.bandCount {
            smooth[band] += (next[band] - smooth[band]) * 0.18
        }
        lock.unlock()
    }

    private func ensureHistoryCapacity() {
        let needed = max(16, min(192, Int((Self.averageSeconds * sampleRate / Double(Self.hopSize)).rounded())))
        guard needed != historyCapacity else { return }
        historyCapacity = needed
        history = [Float](repeating: 0, count: needed * Self.bandCount)
        historySums = [Float](repeating: 0, count: Self.bandCount)
        historyWrite = 0
        historyFilled = 0
    }
}
