import Foundation

/// Runtime knobs for EQ accuracy A/B. UI is gated by `AppConfig.showEQAccuracyDebugSettings`.
public struct AudioEngineDebugOptions: Codable, Equatable, Sendable {
    /// Core Audio `kAudioSubTapDriftCompensationKey`. Shipping default: off (HF accuracy).
    public var tapDriftCompensation: Bool
    /// When non-nil, design biquads at this rate instead of device/aggregate nominal.
    public var eqSampleRateOverrideHz: Double?
    /// Keep the process tap up indefinitely while EQ is soft-bypassed (no silence teardown).
    public var holdTapWhenBypassed: Bool

    public init(
        tapDriftCompensation: Bool = false,
        eqSampleRateOverrideHz: Double? = nil,
        holdTapWhenBypassed: Bool = false
    ) {
        self.tapDriftCompensation = tapDriftCompensation
        self.eqSampleRateOverrideHz = eqSampleRateOverrideHz
        self.holdTapWhenBypassed = holdTapWhenBypassed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tapDriftCompensation = try c.decodeIfPresent(Bool.self, forKey: .tapDriftCompensation) ?? false
        eqSampleRateOverrideHz = try c.decodeIfPresent(Double.self, forKey: .eqSampleRateOverrideHz)
        holdTapWhenBypassed = try c.decodeIfPresent(Bool.self, forKey: .holdTapWhenBypassed) ?? false
    }
}

/// Snapshot of rates / knobs actually in use (for Settings readout).
public struct AudioEngineDiagnostics: Equatable, Sendable {
    public var isRunning: Bool
    public var deviceSampleRateHz: Double?
    public var aggregateSampleRateHz: Double?
    public var tapSampleRateHz: Double?
    public var eqDesignSampleRateHz: Double?
    public var tapDriftCompensation: Bool?
    public var holdTapWhenBypassed: Bool?

    public static let idle = AudioEngineDiagnostics(
        isRunning: false,
        deviceSampleRateHz: nil,
        aggregateSampleRateHz: nil,
        tapSampleRateHz: nil,
        eqDesignSampleRateHz: nil,
        tapDriftCompensation: nil,
        holdTapWhenBypassed: nil
    )

    public var summaryLine: String {
        guard isRunning else { return "Engine idle — arm EQ to capture live rates." }
        func fmt(_ v: Double?) -> String {
            guard let v else { return "—" }
            if abs(v - v.rounded()) < 0.05 { return String(format: "%.0f", v) }
            return String(format: "%.2f", v)
        }
        let drift = tapDriftCompensation.map { $0 ? "on" : "off" } ?? "—"
        let hold = holdTapWhenBypassed.map { $0 ? "hold" : "release" } ?? "—"
        return "device \(fmt(deviceSampleRateHz)) · agg \(fmt(aggregateSampleRateHz)) · tap \(fmt(tapSampleRateHz)) · EQ \(fmt(eqDesignSampleRateHz)) · drift \(drift) · bypass \(hold)"
    }
}
