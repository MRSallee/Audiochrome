import Foundation

public struct EQFilter: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case peaking = "PK"
        case lowShelf = "LS"
        case highShelf = "HS"
        case lowPass = "LP"
        case highPass = "HP"
        case notch = "NO"
        case bandPass = "BP"
        case allPass = "AP"
        case unknown

        /// APO / Squiglink / REW type tokens (LS vs LSC, etc.).
        public static func fromAPOType(_ raw: String) -> Kind {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "PK", "PEQ", "MODAL", "EQ":
                return .peaking
            case "LS", "LSC", "LSH":
                return .lowShelf
            case "HS", "HSC", "HSH":
                return .highShelf
            case "LP", "LPQ":
                return .lowPass
            case "HP", "HPQ":
                return .highPass
            case "NO", "NOTCH":
                return .notch
            case "BP", "BPQ":
                return .bandPass
            case "AP":
                return .allPass
            default:
                return .unknown
            }
        }
    }

    public var enabled: Bool
    public var kind: Kind
    public var frequencyHz: Double
    public var gainDB: Double
    public var q: Double

    public init(enabled: Bool, kind: Kind, frequencyHz: Double, gainDB: Double, q: Double) {
        self.enabled = enabled
        self.kind = kind
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}

public struct ChannelEQ: Equatable, Sendable {
    public var preampDB: Double
    public var filters: [EQFilter]

    public init(preampDB: Double = 0, filters: [EQFilter] = []) {
        self.preampDB = preampDB
        self.filters = filters
    }
}

/// Parsed Equalizer APO / Squiglink / AutoEQ profile.
public struct EQProfile: Equatable, Sendable {
    public var name: String
    /// Stereo-linked curve when there are no Channel: L/R sections.
    public var linked: ChannelEQ?
    public var left: ChannelEQ?
    public var right: ChannelEQ?

    public init(name: String, linked: ChannelEQ? = nil, left: ChannelEQ? = nil, right: ChannelEQ? = nil) {
        self.name = name
        self.linked = linked
        self.left = left
        self.right = right
    }

    public var isMultiChannel: Bool {
        left != nil || right != nil
    }

    /// Effective left curve (L section, else linked).
    public var effectiveLeft: ChannelEQ {
        left ?? linked ?? ChannelEQ()
    }

    /// Effective right curve (R section, else linked / left).
    public var effectiveRight: ChannelEQ {
        right ?? linked ?? left ?? ChannelEQ()
    }

    /// Largest |gain| among enabled filters (used for waveform vertical scale).
    public var maxAbsFilterGainDB: Double {
        let channels = [linked, left, right].compactMap { $0 }
        return channels
            .flatMap(\.filters)
            .filter(\.enabled)
            .map { abs($0.gainDB) }
            .max() ?? 0
    }

    /// Waveform half-range in dB: ±10 by default, or ±max filter gain when larger.
    public var waveformHalfRangeDB: Double {
        max(10, maxAbsFilterGainDB)
    }
}

/// Menu EQ curve preview: samples plus vertical scale (±halfRangeDB).
public struct EQFrequencyResponsePreview: Equatable, Sendable {
    public var magnitudesDB: [Double]
    public var halfRangeDB: Double

    public init(magnitudesDB: [Double], halfRangeDB: Double) {
        self.magnitudesDB = magnitudesDB
        self.halfRangeDB = halfRangeDB
    }
}

public struct ProfileFile: Identifiable, Equatable, Sendable {
    public var id: String { filename }
    public var filename: String
    public var displayName: String
    public var url: URL

    public init(filename: String, url: URL) {
        self.filename = filename
        self.url = url
        self.displayName = (filename as NSString).deletingPathExtension
    }
}
