import Foundation

public struct EQFilter: Equatable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
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

        /// Token written by `ProfileWriter` (`nil` = skip).
        public var apoType: String? {
            switch self {
            case .peaking: return "PK"
            case .lowShelf: return "LS"
            case .highShelf: return "HS"
            case .lowPass: return "LP"
            case .highPass: return "HP"
            case .notch: return "NO"
            case .bandPass: return "BP"
            case .allPass: return "AP"
            case .unknown: return nil
            }
        }

        public static let editorKinds: [Kind] = [.lowShelf, .peaking, .highShelf]

        public var isEditorKind: Bool { Self.editorKinds.contains(self) }

        public var editorLabel: String {
            switch self {
            case .peaking: return "PEAK"
            case .lowShelf: return "LSQ"
            case .highShelf: return "HSQ"
            default: return rawValue
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

    /// Full vertical span of the EQ curve preview (dB). Window is centered on the curve, not 0 dB.
    public static let waveformRangeDB: Double = 30

    /// Waveform half-range in dB (±15 → 30 dB full scale).
    public var waveformHalfRangeDB: Double {
        Self.waveformRangeDB / 2
    }

    /// Default new-profile curve: one peaking band at 1 kHz / 0 dB / Q 1.
    public static func makeNew(name: String = "New Profile") -> EQProfile {
        EQProfile(
            name: name,
            linked: ChannelEQ(
                preampDB: 0,
                filters: [
                    EQFilter(enabled: true, kind: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1)
                ]
            )
        )
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
