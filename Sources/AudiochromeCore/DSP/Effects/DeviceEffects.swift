import Foundation

/// Per-output effect slots. Lives on `OutputMapping`, not on an EQ profile —
/// swap profiles and these stay; swap devices and you get that device’s state.
public struct DeviceEffects: Codable, Equatable, Sendable {
    public var saturation: SaturationSettings
    public var crossfeed: CrossfeedSettings
    public var subharmonic: SubharmonicSettings

    public init(
        saturation: SaturationSettings = .off,
        crossfeed: CrossfeedSettings = .off,
        subharmonic: SubharmonicSettings = .off
    ) {
        self.saturation = saturation
        self.crossfeed = crossfeed
        self.subharmonic = subharmonic
    }

    private enum CodingKeys: String, CodingKey {
        case saturation, crossfeed, subharmonic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        saturation = try container.decodeIfPresent(SaturationSettings.self, forKey: .saturation) ?? .off
        crossfeed = try container.decodeIfPresent(CrossfeedSettings.self, forKey: .crossfeed) ?? .off
        subharmonic = try container.decodeIfPresent(SubharmonicSettings.self, forKey: .subharmonic) ?? .off
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(crossfeed, forKey: .crossfeed)
        try container.encode(subharmonic, forKey: .subharmonic)
    }

    public static let off = DeviceEffects()

    public var isAudible: Bool {
        EffectsFeature.isEnabled && (saturation.enabled || crossfeed.enabled || subharmonic.enabled)
    }

    public var enabledDisplayNames: [String] {
        guard EffectsFeature.isEnabled else { return [] }
        var names: [String] = []
        if saturation.enabled { names.append(EffectKind.saturation.title) }
        if subharmonic.enabled { names.append(EffectKind.subharmonic.title) }
        if crossfeed.enabled { names.append(EffectKind.crossfeed.title) }
        return names
    }

    public var signature: String {
        guard EffectsFeature.isEnabled else { return "off" }
        return "sat:\(saturation.signature)|sh:\(subharmonic.signature)|xf:\(crossfeed.signature)"
    }

    public func isEnabled(_ kind: EffectKind) -> Bool {
        switch kind {
        case .saturation: return saturation.enabled
        case .subharmonic: return subharmonic.enabled
        case .crossfeed: return crossfeed.enabled
        }
    }

    public mutating func setEnabled(_ enabled: Bool, for kind: EffectKind) {
        switch kind {
        case .saturation: saturation.enabled = enabled
        case .subharmonic: subharmonic.enabled = enabled
        case .crossfeed: crossfeed.enabled = enabled
        }
    }

    public static var listedKinds: [EffectKind] {
        guard EffectsFeature.isEnabled else { return [] }
        return EffectKind.allCases
    }
}

public enum EffectKind: String, CaseIterable, Identifiable, Sendable {
    case saturation
    case subharmonic
    case crossfeed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .saturation: return "Saturation"
        case .subharmonic: return "Subharmonics"
        case .crossfeed: return "Crossfeed"
        }
    }
}

/// Complementary mix amount. UI 100% = `g` of 0.5 (same bass in both ears).
public enum CrossfeedBleed: Int, CaseIterable, Codable, Identifiable, Sendable {
    case ten = 10
    case twenty = 20
    case fifty = 50
    case seventyFive = 75
    case full = 100

    public var id: Int { rawValue }
    public var title: String { "\(rawValue)%" }

    /// Processor mix `g`. Full = 0.5 so a hard-pan becomes mono at DC.
    public var mix: Double { 0.5 * Double(rawValue) / 100.0 }

    /// Opposite-ear level vs the source ear for a hard-panned bass tone.
    /// `20 · log10(g / (1 − g))` — more bleed approaches `0dB`.
    public var differenceLabel: String {
        let g = mix
        let db = (g > 0 && g < 1) ? 20.0 * log10(g / (1.0 - g)) : 0
        let rounded = (db * 10).rounded() / 10
        if abs(rounded) < 0.05 {
            return "0dB"
        }
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))dB"
        }
        return String(format: "%.1fdB", rounded)
    }

    public static func nearest(toPercent percent: Double) -> CrossfeedBleed {
        allCases.min(by: { abs(Double($0.rawValue) - percent) < abs(Double($1.rawValue) - percent) }) ?? .fifty
    }
}

/// How high the bleed reaches. One-pole lowpass; “20 Hz” is implicit (from DC).
public enum CrossfeedRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case sub
    case bass
    case mid
    case voice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sub: return "Sub"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .voice: return "Vocal"
        }
    }

    public var bandLabel: String {
        switch self {
        case .sub: return "20 - 80Hz"
        case .bass: return "20 - 300Hz"
        case .mid: return "20 - 1kHz"
        case .voice: return "20 - 3kHz"
        }
    }

    public var cutoffHz: Double {
        switch self {
        case .sub: return 80
        case .bass: return 300
        case .mid: return 1_000
        case .voice: return 3_000
        }
    }

    /// `|H|` of the one-pole the processor uses: `a = 1 − exp(−2π fc / sr)`.
    public func lowpassGain(atHz hz: Double, sampleRate: Double = 48_000) -> Double {
        let rate = max(sampleRate, 1)
        let freq = min(max(hz, 0), rate * 0.5)
        let omega = 2.0 * Double.pi * freq / rate
        let coeff = 1.0 - exp(-2.0 * Double.pi * cutoffHz / rate)
        let pole = 1.0 - coeff
        let denom = sqrt(1.0 + pole * pole - 2.0 * pole * cos(omega))
        return denom > 0 ? coeff / denom : 0
    }

    public static func nearest(toCutoffHz hz: Double) -> CrossfeedRange {
        allCases.min(by: { abs($0.cutoffHz - hz) < abs($1.cutoffHz - hz) }) ?? .mid
    }
}

/// Opposite-channel ITD. Focused = level-only; Diffuse = a little room.
/// Unlabeled stops sit between the named ones.
public enum CrossfeedImage: String, CaseIterable, Codable, Identifiable, Sendable {
    case focused
    case nearFocused
    case midFocused
    case natural
    case midDiffuse
    case nearDiffuse
    case diffuse

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focused: return "Focused"
        case .nearFocused, .midFocused, .midDiffuse, .nearDiffuse: return ""
        case .natural: return "Natural"
        case .diffuse: return "Diffuse"
        }
    }

    public var delayMicroseconds: Double {
        switch self {
        case .focused: return 0
        case .nearFocused: return 110
        case .midFocused: return 220
        case .natural: return 330
        case .midDiffuse: return 433
        case .nearDiffuse: return 537
        case .diffuse: return 640
        }
    }

    public var delayLabel: String {
        "\(Int(delayMicroseconds.rounded()))µs"
    }

    /// Plot softness. 0 = Focused, 1 = Diffuse (today’s former Natural look).
    public var diffusion: Double {
        delayMicroseconds / Self.diffuse.delayMicroseconds
    }

    public static func nearest(toDelayMicroseconds us: Double) -> CrossfeedImage {
        allCases.min(by: {
            abs($0.delayMicroseconds - us) < abs($1.delayMicroseconds - us)
        }) ?? .natural
    }
}

public struct CrossfeedTune: Codable, Equatable, Sendable {
    public var bleed: CrossfeedBleed
    public var range: CrossfeedRange
    public var image: CrossfeedImage

    public static let middle = CrossfeedTune(bleed: .fifty, range: .mid, image: .natural)

    public init(
        bleed: CrossfeedBleed = Self.middle.bleed,
        range: CrossfeedRange = Self.middle.range,
        image: CrossfeedImage = Self.middle.image
    ) {
        self.bleed = bleed
        self.range = range
        self.image = image
    }
}

public struct CrossfeedSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var bleed: CrossfeedBleed
    public var range: CrossfeedRange
    public var image: CrossfeedImage
    /// Last non-preset tweak. Clicking Custom recalls this; the next tweak replaces it.
    public var custom: CrossfeedTune
    /// Which list row is selected. Tweaking sliders locks this to Custom
    /// even if the values match a factory preset.
    public var preset: CrossfeedPreset

    public static let off = CrossfeedSettings()

    public init(
        enabled: Bool = false,
        bleed: CrossfeedBleed = CrossfeedPreset.subtleStage.tune.bleed,
        range: CrossfeedRange = CrossfeedPreset.subtleStage.tune.range,
        image: CrossfeedImage = CrossfeedPreset.subtleStage.tune.image,
        custom: CrossfeedTune = .middle,
        preset: CrossfeedPreset = .subtleStage
    ) {
        self.enabled = enabled
        self.bleed = bleed
        self.range = range
        self.image = image
        self.custom = custom
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, bleed, range, image, custom, preset
        case cutoffHz, feedDB, delayMicroseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        custom = try container.decodeIfPresent(CrossfeedTune.self, forKey: .custom) ?? .middle
        if let bleed = try container.decodeIfPresent(CrossfeedBleed.self, forKey: .bleed),
           let range = try container.decodeIfPresent(CrossfeedRange.self, forKey: .range),
           let image = try container.decodeIfPresent(CrossfeedImage.self, forKey: .image) {
            self.bleed = bleed
            self.range = range
            self.image = image
            preset = try container.decodeIfPresent(CrossfeedPreset.self, forKey: .preset)
                ?? CrossfeedPreset.inferred(bleed: bleed, range: range, image: image)
            return
        }

        let feedDB = try container.decodeIfPresent(Double.self, forKey: .feedDB)
        let cutoffHz = try container.decodeIfPresent(Double.self, forKey: .cutoffHz)
        let delayUs = try container.decodeIfPresent(Double.self, forKey: .delayMicroseconds)
        bleed = Self.migrateBleed(feedDB: feedDB)
        range = cutoffHz.map(CrossfeedRange.nearest(toCutoffHz:)) ?? CrossfeedPreset.subtleStage.tune.range
        image = delayUs.map(CrossfeedImage.nearest(toDelayMicroseconds:))
            ?? CrossfeedPreset.subtleStage.tune.image
        preset = try container.decodeIfPresent(CrossfeedPreset.self, forKey: .preset)
            ?? CrossfeedPreset.inferred(bleed: bleed, range: range, image: image)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(bleed, forKey: .bleed)
        try container.encode(range, forKey: .range)
        try container.encode(image, forKey: .image)
        try container.encode(custom, forKey: .custom)
        try container.encode(preset, forKey: .preset)
    }

    public var selectedPreset: CrossfeedPreset { preset }

    public var signature: String {
        let on = enabled ? 1 : 0
        return "\(on):\(bleed.rawValue):\(range.rawValue):\(image.rawValue)"
    }

    public mutating func apply(_ preset: CrossfeedPreset) {
        self.preset = preset
        let tune = preset == .custom ? custom : preset.tune
        bleed = tune.bleed
        range = tune.range
        image = tune.image
    }

    public mutating func captureCustom() {
        custom = CrossfeedTune(bleed: bleed, range: range, image: image)
        preset = .custom
    }

    public mutating func sanitize() {}

    /// Old `feedDB` (ILD) → UI percent, then snap to a stop.
    private static func migrateBleed(feedDB: Double?) -> CrossfeedBleed {
        guard let feedDB else { return CrossfeedPreset.subtleStage.tune.bleed }
        let k = pow(10.0, -feedDB / 20.0)
        let g = k / (1.0 + k)
        return .nearest(toPercent: 2.0 * g * 100.0)
    }
}

public enum CrossfeedPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case subtleStage
    case wideStage
    case hardPanFixer
    case custom

    public var id: String { rawValue }

    public static var factoryCases: [CrossfeedPreset] {
        allCases.filter { $0 != .custom }
    }

    public var title: String {
        switch self {
        case .wideStage: return "Wide"
        case .subtleStage: return "Subtle"
        case .hardPanFixer: return "De-pan"
        case .custom: return "Custom"
        }
    }

    public var tune: CrossfeedTune {
        switch self {
        case .hardPanFixer:
            return CrossfeedTune(bleed: .full, range: .voice, image: .focused)
        case .wideStage:
            return CrossfeedTune(bleed: .seventyFive, range: .mid, image: .diffuse)
        case .subtleStage:
            return CrossfeedTune(bleed: .fifty, range: .bass, image: .natural)
        case .custom:
            return .middle
        }
    }

    fileprivate static func inferred(
        bleed: CrossfeedBleed,
        range: CrossfeedRange,
        image: CrossfeedImage
    ) -> CrossfeedPreset {
        factoryCases.first {
            $0.tune.bleed == bleed && $0.tune.range == range && $0.tune.image == image
        } ?? .custom
    }
}
