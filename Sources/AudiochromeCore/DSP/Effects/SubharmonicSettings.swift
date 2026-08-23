import Foundation

/// Mix of the generated octave-down. UI 100% is a safe wet gain, not 1:1 add.
public enum SubharmonicAmount: Int, CaseIterable, Codable, Identifiable, Sendable {
    case ten = 10
    case twentyFive = 25
    case fifty = 50
    case seventyFive = 75
    case full = 100

    public var id: Int { rawValue }
    public var title: String { "\(rawValue)%" }

    /// Linear wet gain. Full = 0.42 so a 0 dBFS kick doesn’t clip the sum.
    public var mix: Double { 0.42 * Double(rawValue) / 100.0 }

    /// Wet add vs dry, `20 · log10(mix)`.
    public var wetLabel: String {
        let gain = mix
        guard gain > 0 else { return "-infdB" }
        let db = 20.0 * log10(gain)
        let rounded = (db * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))dB"
        }
        return String(format: "%.1fdB", rounded)
    }
}

/// How high we listen, and how high the generated sub is allowed to go.
public enum SubharmonicRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case deep
    case sub
    case bass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deep: return "Deep"
        case .sub: return "Sub"
        case .bass: return "Bass"
        }
    }

    public var bandLabel: String {
        let hz = Int(subLowpassHz.rounded())
        return "20 - \(hz)Hz"
    }

    /// `|H|` of the generated-sub one-pole the processor uses.
    public func lowpassGain(atHz hz: Double, sampleRate: Double = 48_000) -> Double {
        let rate = max(sampleRate, 1)
        let freq = min(max(hz, 0), rate * 0.5)
        let omega = 2.0 * Double.pi * freq / rate
        let coeff = 1.0 - exp(-2.0 * Double.pi * subLowpassHz / rate)
        let pole = 1.0 - coeff
        let denom = sqrt(1.0 + pole * pole - 2.0 * pole * cos(omega))
        return denom > 0 ? coeff / denom : 0
    }

    /// One-pole extract cutoff on the mid signal.
    public var extractHz: Double {
        switch self {
        case .deep: return 80
        case .sub: return 120
        case .bass: return 180
        }
    }

    /// One-pole on the square-wave divider (keeps the sub in-band).
    public var subLowpassHz: Double {
        switch self {
        case .deep: return 42
        case .sub: return 62
        case .bass: return 90
        }
    }
}

public struct SubharmonicTune: Codable, Equatable, Sendable {
    public var amount: SubharmonicAmount
    public var range: SubharmonicRange

    public static let middle = SubharmonicTune(amount: .fifty, range: .sub)

    public init(
        amount: SubharmonicAmount = Self.middle.amount,
        range: SubharmonicRange = Self.middle.range
    ) {
        self.amount = amount
        self.range = range
    }
}

public struct SubharmonicSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var amount: SubharmonicAmount
    public var range: SubharmonicRange
    public var custom: SubharmonicTune
    /// Which list row is selected. Tweaking sliders locks this to Custom
    /// even if the values match a factory preset.
    public var preset: SubharmonicPreset

    public static let off = SubharmonicSettings()

    public init(
        enabled: Bool = false,
        amount: SubharmonicAmount = SubharmonicPreset.subtle.tune.amount,
        range: SubharmonicRange = SubharmonicPreset.subtle.tune.range,
        custom: SubharmonicTune = .middle,
        preset: SubharmonicPreset = .subtle
    ) {
        self.enabled = enabled
        self.amount = amount
        self.range = range
        self.custom = custom
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, amount, range, custom, preset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        amount = try container.decodeIfPresent(SubharmonicAmount.self, forKey: .amount)
            ?? SubharmonicPreset.subtle.tune.amount
        range = try container.decodeIfPresent(SubharmonicRange.self, forKey: .range)
            ?? SubharmonicPreset.subtle.tune.range
        custom = try container.decodeIfPresent(SubharmonicTune.self, forKey: .custom) ?? .middle
        preset = try container.decodeIfPresent(SubharmonicPreset.self, forKey: .preset)
            ?? SubharmonicPreset.inferred(amount: amount, range: range)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(amount, forKey: .amount)
        try container.encode(range, forKey: .range)
        try container.encode(custom, forKey: .custom)
        try container.encode(preset, forKey: .preset)
    }

    public var selectedPreset: SubharmonicPreset { preset }

    public var signature: String {
        let on = enabled ? 1 : 0
        return "\(on):\(amount.rawValue):\(range.rawValue)"
    }

    public mutating func apply(_ preset: SubharmonicPreset) {
        self.preset = preset
        let tune = preset == .custom ? custom : preset.tune
        amount = tune.amount
        range = tune.range
    }

    public mutating func captureCustom() {
        custom = SubharmonicTune(amount: amount, range: range)
        preset = .custom
    }

    public mutating func sanitize() {}
}

public enum SubharmonicPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case subtle
    case punch
    case club
    case custom

    public var id: String { rawValue }

    public static var factoryCases: [SubharmonicPreset] {
        allCases.filter { $0 != .custom }
    }

    public var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .punch: return "Punch"
        case .club: return "Club"
        case .custom: return "Custom"
        }
    }

    public var tune: SubharmonicTune {
        switch self {
        case .subtle:
            return SubharmonicTune(amount: .twentyFive, range: .deep)
        case .punch:
            return SubharmonicTune(amount: .fifty, range: .sub)
        case .club:
            return SubharmonicTune(amount: .seventyFive, range: .bass)
        case .custom:
            return .middle
        }
    }

    fileprivate static func inferred(
        amount: SubharmonicAmount,
        range: SubharmonicRange
    ) -> SubharmonicPreset {
        factoryCases.first {
            $0.tune.amount == amount && $0.tune.range == range
        } ?? .custom
    }
}
