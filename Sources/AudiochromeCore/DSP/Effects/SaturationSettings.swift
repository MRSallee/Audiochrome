import Foundation

/// Harmonic amount as % THD through that family alone, 0 dBFS sine.
/// Even is \(x^{2}\) (H2 only). Odd is a unity-gain soft clip.
public enum SaturationAmount: Double, CaseIterable, Codable, Identifiable, Sendable {
    case low = 0.05
    case two = 2
    case five = 5
    case ten = 10
    case twenty = 20

    public var id: Double { rawValue }

    /// Tick under the slider. Empty stops stay unlabeled.
    public var title: String {
        switch self {
        case .low: return "Low"
        case .two: return ""
        case .five: return "High"
        case .ten: return ""
        case .twenty: return "Extreme"
        }
    }

    /// Heading sub-label: the actual THD percent.
    public var percentLabel: String {
        switch self {
        case .low: return "0.05%"
        case .two, .five, .ten, .twenty:
            return "\(Int(rawValue))%"
        }
    }

    /// Plot height only — not the DSP amount. Stops are spaced so Low→2%
    /// is not a log cliff; Extreme is still the top of the chart.
    public var plotNorm: Double {
        switch self {
        case .low: return 0.16
        case .two: return 0.34
        case .five: return 0.54
        case .ten: return 0.74
        case .twenty: return 1
        }
    }

    /// Gain on DC-blocked \(x^{2}\) so a 0 dBFS sine’s H2 / H1 matches `rawValue` %.
    public var evenMix: Double { 2.0 * rawValue / 100.0 }

    /// Processor mix so Odd-only THD matches `rawValue` % (0 dBFS sine).
    public var oddMix: Double {
        switch self {
        case .low: return 0.0059
        case .two: return 0.2191
        case .five: return 0.4929
        case .ten: return 0.8447
        case .twenty: return 1.3135
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value: Double
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let number = try? container.decode(Int.self) {
            value = Double(number)
        } else {
            self = .five
            return
        }
        self = Self.closest(to: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func closest(to value: Double) -> SaturationAmount {
        allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .five
    }
}

/// Which part of the spectrum is allowed to hit the curves. The rest stays dry.
public enum SaturationBandwidth: String, CaseIterable, Codable, Identifiable, Sendable {
    case bass
    case edges
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bass: return "Bass"
        case .edges: return "Edges"
        case .full: return "Full"
        }
    }

    public var bandLabel: String {
        switch self {
        case .bass: return "20 - 300Hz"
        case .edges: return "20-300Hz + 3.5kHz+"
        case .full: return "20Hz - 20kHz"
        }
    }

    /// Bass extract −3 dB (2-pole Butterworth). Used when Bandwidth is Bass or Edges.
    public var bassHz: Double { 300 }

    /// Air extract −3 dB (2-pole Butterworth). Edges only.
    public var airHz: Double { 3_500 }

    /// How much of a sine at `hz` hits the shapers. Matches the processor split.
    public func driveGain(atHz hz: Double, sampleRate: Double = 48_000) -> Double {
        _ = sampleRate
        let freq = max(hz, 1)
        switch self {
        case .full:
            return 1
        case .bass:
            return Self.butterworthLowpass(cutoffHz: bassHz, atHz: freq, order: 2)
        case .edges:
            let bass = Self.butterworthLowpass(cutoffHz: bassHz, atHz: freq, order: 2)
            let air = Self.butterworthHighpass(cutoffHz: airHz, atHz: freq, order: 2)
            return min(1, bass + air)
        }
    }

    /// |H| of an analog Butterworth lowpass, `order` poles.
    public static func butterworthLowpass(cutoffHz: Double, atHz hz: Double, order: Int) -> Double {
        let ratio = max(hz, 0) / max(cutoffHz, 1)
        return 1.0 / sqrt(1.0 + pow(ratio, 2.0 * Double(order)))
    }

    /// |H| of an analog Butterworth highpass, `order` poles.
    public static func butterworthHighpass(cutoffHz: Double, atHz hz: Double, order: Int) -> Double {
        let ratio = max(cutoffHz, 1) / max(hz, 1)
        return 1.0 / sqrt(1.0 + pow(ratio, 2.0 * Double(order)))
    }
}

/// One-pole on drive, not on the wet audio. Off = stateless shaper.
public enum SaturationMemory: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case on

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        }
    }

    public var timeLabel: String {
        switch self {
        case .off: return "Off"
        case .on: return "40ms"
        }
    }

    public var seconds: Double {
        switch self {
        case .off: return 0
        case .on: return 0.040
        }
    }

    /// How far the envelope is allowed to push drive. 0 = unused.
    public var depth: Double {
        switch self {
        case .off: return 0
        case .on: return 0.75
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "off": self = .off
        case "on", "little", "more": self = .on
        default: self = .off
        }
    }
}

public struct SaturationTune: Codable, Equatable, Sendable {
    public var even: SaturationAmount
    public var odd: SaturationAmount
    public var bandwidth: SaturationBandwidth
    public var memory: SaturationMemory

    public static let middle = SaturationTune(
        even: .five,
        odd: .low,
        bandwidth: .bass,
        memory: .off
    )

    public init(
        even: SaturationAmount = Self.middle.even,
        odd: SaturationAmount = Self.middle.odd,
        bandwidth: SaturationBandwidth = Self.middle.bandwidth,
        memory: SaturationMemory = Self.middle.memory
    ) {
        self.even = even
        self.odd = odd
        self.bandwidth = bandwidth
        self.memory = memory
    }
}

public struct SaturationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var even: SaturationAmount
    public var odd: SaturationAmount
    public var bandwidth: SaturationBandwidth
    public var memory: SaturationMemory
    public var custom: SaturationTune
    /// Which list row is selected. Tweaking sliders locks this to Custom
    /// even if the values match a factory preset.
    public var preset: SaturationPreset

    public static let off = SaturationSettings()

    public init(
        enabled: Bool = false,
        even: SaturationAmount = SaturationPreset.tube.tune.even,
        odd: SaturationAmount = SaturationPreset.tube.tune.odd,
        bandwidth: SaturationBandwidth = SaturationPreset.tube.tune.bandwidth,
        memory: SaturationMemory = SaturationPreset.tube.tune.memory,
        custom: SaturationTune = .middle,
        preset: SaturationPreset = .tube
    ) {
        self.enabled = enabled
        self.even = even
        self.odd = odd
        self.bandwidth = bandwidth
        self.memory = memory
        self.custom = custom
        self.preset = preset
    }

    public var selectedPreset: SaturationPreset { preset }

    public var signature: String {
        let on = enabled ? 1 : 0
        return "\(on):\(even.rawValue):\(odd.rawValue):\(bandwidth.rawValue):\(memory.rawValue)"
    }

    public mutating func apply(_ preset: SaturationPreset) {
        self.preset = preset
        let tune = preset == .custom ? custom : preset.tune
        even = tune.even
        odd = tune.odd
        bandwidth = tune.bandwidth
        memory = tune.memory
    }

    public mutating func captureCustom() {
        custom = SaturationTune(even: even, odd: odd, bandwidth: bandwidth, memory: memory)
        preset = .custom
    }

    public mutating func sanitize() {}
}

public enum SaturationPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case tube
    case tape
    case edge
    case custom

    public var id: String { rawValue }

    public static var factoryCases: [SaturationPreset] {
        allCases.filter { $0 != .custom }
    }

    public var title: String {
        switch self {
        case .tube: return "Tube"
        case .tape: return "Tape"
        case .edge: return "Edge"
        case .custom: return "Custom"
        }
    }

    public var tune: SaturationTune {
        switch self {
        case .tube:
            return SaturationTune(even: .ten, odd: .low, bandwidth: .bass, memory: .off)
        case .tape:
            return SaturationTune(even: .five, odd: .two, bandwidth: .full, memory: .on)
        case .edge:
            return SaturationTune(even: .low, odd: .ten, bandwidth: .full, memory: .off)
        case .custom:
            return .middle
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "tube": self = .tube
        case "tape": self = .tape
        case "edge": self = .edge
        case "custom": self = .custom
        case "subtle": self = .tube
        default: self = .tube
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
