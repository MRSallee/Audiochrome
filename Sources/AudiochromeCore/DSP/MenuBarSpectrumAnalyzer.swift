import Accelerate
import Foundation

/// Menu-bar visualizer styles. Flip `style` to try one; not in Settings yet.
public enum MenuBarIconStyle: String, Sendable, CaseIterable {
    /// 12-lobe star, 20 Hz at 12 o’clock clockwise to 20 kHz.
    case star
    /// Five vertical capsules inscribed in the plate.
    case bars
}

public enum MenuBarSpectrum {
    /// Active icon animation. Star is pinned here for later; bars is the current experiment.
    public static let style: MenuBarIconStyle = .bars

    public static var frequencies: [Float] {
        switch style {
        case .star:
            return [20, 40, 80, 160, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 20_000]
        case .bars:
            /// Centers; each bar uses a range around these (see `installBandWindows`).
            return [80, 250, 1_000, 4_000, 16_000]
        }
    }

    public static var bandCount: Int { frequencies.count }
}

/// Rest-state 5-bar mark (menu-bar icon and profile list).
public enum MenuBarBarsMark {
    public static let count = 5
    public static let barWidth: CGFloat = 2
    public static let gap: CGFloat = 0.5
    public static let heights: [CGFloat] = [6, 10, 12, 10, 6]

    /// 26pt list / in-app plate. Wider gaps so the five pills read at that size.
    public enum List {
        public static let designSize: CGFloat = 26
        public static let barWidth: CGFloat = 2
        public static let gap: CGFloat = 1.5
        public static let heights: [CGFloat] = [10, 16, 18, 16, 10]
    }

    public static func barFrames(center: CGPoint, scale: CGFloat = 1) -> [CGRect] {
        frames(center: center, scale: scale, width: barWidth, gap: gap, heights: heights)
    }

    public static func listBarFrames(center: CGPoint, size: CGFloat) -> [CGRect] {
        frames(
            center: center,
            scale: size / List.designSize,
            width: List.barWidth,
            gap: List.gap,
            heights: List.heights
        )
    }

    private static func frames(
        center: CGPoint,
        scale: CGFloat,
        width: CGFloat,
        gap: CGFloat,
        heights: [CGFloat]
    ) -> [CGRect] {
        let bar = width * scale
        let spacing = gap * scale
        let totalWidth = CGFloat(count) * bar + CGFloat(count - 1) * spacing
        let firstX = center.x - totalWidth / 2
        return (0..<count).map { i in
            let height = heights[i] * scale
            return CGRect(
                x: firstX + CGFloat(i) * (bar + spacing),
                y: center.y - height / 2,
                width: bar,
                height: height
            )
        }
    }
}

/// Real-time menu-bar analyzer. Feed pre-EQ tap audio; read `levels` from the main thread.
public final class MenuBarSpectrumAnalyzer: @unchecked Sendable {
    public static var bandCount: Int { MenuBarSpectrum.bandCount }

    private let bandCount: Int
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
    /// 0…1 spike height (0 = playing floor, 1 = plate edge).
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
    private var mixPeak: Float = 0
    private var bandPeak: [Float]
    private static let averageSeconds: Double = 2
    /// Spike height uses this window, not each FFT hop.
    private static let displaySeconds: Double = 0.1

    public init() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP FFT setup failed")
        }
        fftSetup = setup
        bandCount = MenuBarSpectrum.bandCount
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: Self.fftSize)
        time = [Float](repeating: 0, count: Self.fftSize)
        realp = [Float](repeating: 0, count: Self.fftSize / 2)
        imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        smooth = [Float](repeating: 0, count: bandCount)
        historyCapacity = 96
        history = [Float](repeating: 0, count: 96 * bandCount)
        historySums = [Float](repeating: 0, count: bandCount)
        loHz = [Float](repeating: 0, count: bandCount)
        hiHz = [Float](repeating: 0, count: bandCount)
        bandPeak = [Float](repeating: 0.02, count: bandCount)
        installBandWindows()
    }

    private func installBandWindows() {
        switch MenuBarSpectrum.style {
        case .star:
            let f = MenuBarSpectrum.frequencies
            let ratio: Float = pow(2, 0.22)
            for i in 0..<bandCount {
                loHz[i] = f[i] / ratio
                hiHz[i] = f[i] * ratio
            }
        case .bars:
            let windows: [(Float, Float)] = [
                (40, 160),
                (125, 500),
                (500, 2_000),
                (2_000, 8_000),
                (6_000, 20_000)
            ]
            for i in 0..<min(bandCount, windows.count) {
                loHz[i] = windows[i].0
                hiHz[i] = windows[i].1
            }
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
        mixPeak = 0
        for i in 0..<bandPeak.count { bandPeak[i] = 0.02 }
        for i in 0..<historySums.count { historySums[i] = 0 }
        for i in 0..<history.count { history[i] = 0 }
        lock.lock()
        for i in 0..<smooth.count { smooth[i] = 0 }
        lock.unlock()
    }

    /// Latest band heights, 0…1. Safe to read from the main thread.
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

        var next = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let lo = loHz[band]
            let hi = min(hiHz[band], nyquist)
            guard hi > lo, binHz > 0 else { continue }
            let i0 = max(1, Int(lo / binHz))
            let i1 = min(lastBin, Int(ceil(Double(hi / binHz))))
            guard i1 >= i0 else { continue }
            var peak: Float = 0
            var sum: Float = 0
            for i in i0...i1 {
                let m = magnitudes[i]
                peak = max(peak, m)
                sum += m
            }
            let mean = sum / Float(i1 - i0 + 1)
            var mag = sqrt(max(0, peak * 0.55 + mean * 0.45))
            if MenuBarSpectrum.style == .bars, band < MenuBarSpectrum.frequencies.count {
                mag *= pow(max(MenuBarSpectrum.frequencies[band], 80) / 1_000, 0.32)
            }

            let slot = historyWrite * bandCount + band
            if historyFilled == historyCapacity {
                historySums[band] -= history[slot]
            }
            history[slot] = mag
            historySums[band] += mag
        }

        let longCount = historyFilled == historyCapacity ? historyCapacity : historyFilled + 1
        let recentCount = min(shortCount, longCount)
        var shorts = [Float](repeating: 0, count: bandCount)
        var longs = [Float](repeating: 0, count: bandCount)
        var frameMax: Float = 0
        for band in 0..<bandCount {
            let longAverage = historySums[band] / Float(max(longCount, 1))
            var shortSum: Float = 0
            for step in 0..<recentCount {
                let idx = (historyWrite - step + historyCapacity) % historyCapacity
                shortSum += history[idx * bandCount + band]
            }
            let shortAverage = shortSum / Float(max(recentCount, 1))
            shorts[band] = shortAverage
            longs[band] = longAverage
            frameMax = max(frameMax, shortAverage)
        }
        if frameMax > mixPeak {
            mixPeak = frameMax
        } else {
            mixPeak += (frameMax - mixPeak) * 0.05
        }
        var ranked = shorts
        ranked.sort()
        let lower = ranked[max(0, bandCount / 3)]
        let denom = max(mixPeak - lower * 0.8, 1e-4)
        for band in 0..<bandCount {
            if longs[band] < 1e-5, shorts[band] < 1e-5 {
                next[band] = 0
                continue
            }
            let ratio = shorts[band] / max(longs[band], 1e-5)
            let punch = min(1, max(0, log2(max(ratio, 1e-6)) * 1.8))
            if MenuBarSpectrum.style == .bars {
                if shorts[band] > bandPeak[band] {
                    bandPeak[band] += (shorts[band] - bandPeak[band]) * 0.4
                } else {
                    bandPeak[band] += (shorts[band] - bandPeak[band]) * 0.025
                }
                let shape = min(1, shorts[band] / max(bandPeak[band], 1e-5))
                next[band] = min(1, shape * 0.78 + punch * 0.45)
            } else {
                let lifted = max(0, shorts[band] - lower * 0.8)
                let shape = min(1, lifted / denom)
                next[band] = min(1, pow(shape, 1.25) * 0.72 + punch * 0.62)
            }
        }
        historyWrite += 1
        if historyWrite == historyCapacity { historyWrite = 0 }
        if historyFilled < historyCapacity { historyFilled += 1 }

        lock.lock()
        for band in 0..<bandCount {
            let target = next[band]
            let release: Float = MenuBarSpectrum.style == .bars ? 1 : 0.0225
            let rate: Float = target > smooth[band] ? 0.7 : release
            smooth[band] += (target - smooth[band]) * rate
        }
        lock.unlock()
    }

    private func ensureHistoryCapacity() {
        let needed = max(16, min(192, Int((Self.averageSeconds * sampleRate / Double(Self.hopSize)).rounded())))
        guard needed != historyCapacity else { return }
        historyCapacity = needed
        history = [Float](repeating: 0, count: needed * bandCount)
        historySums = [Float](repeating: 0, count: bandCount)
        historyWrite = 0
        historyFilled = 0
    }
}
