import Foundation

public struct ProfileEditorBand: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filter: EQFilter

    public init(id: UUID = UUID(), filter: EQFilter) {
        self.id = id
        self.filter = filter
    }
}

public enum ProfileEditorChannel: String, Equatable, Hashable, Sendable, CaseIterable {
    case both
    case left
    case right

    public var title: String {
        switch self {
        case .both: return "Both channels"
        case .left: return "Left channel"
        case .right: return "Right channel"
        }
    }
}

/// In-panel PEQ editor state. Both-channel filters plus optional L/R-only bands.
public struct ProfileEditorDraft: Equatable, Sendable {
    public var identityKey: String
    public var originalFilename: String?
    public var name: String
    public var colorHex: String
    public var preampDB: Double
    public var bands: [ProfileEditorBand]
    public var leftBands: [ProfileEditorBand]
    public var rightBands: [ProfileEditorBand]
    /// LP/HP/notch/etc. kept on save but not shown in the 2.0 UI.
    public var hiddenFilters: [EQFilter]
    public var hiddenLeftFilters: [EQFilter]
    public var hiddenRightFilters: [EQFilter]
    public var expandedBandID: UUID?
    public var revision: Int

    public var allEditorBands: [ProfileEditorBand] {
        bands + leftBands + rightBands
    }

    public var eqProfile: EQProfile {
        let linkedFilters = bands.map(\.filter) + hiddenFilters
        let leftFilters = leftBands.map(\.filter) + hiddenLeftFilters
        let rightFilters = rightBands.map(\.filter) + hiddenRightFilters
        return EQProfile(
            name: name,
            linked: ChannelEQ(preampDB: preampDB, filters: linkedFilters),
            left: leftFilters.isEmpty ? nil : ChannelEQ(filters: leftFilters),
            right: rightFilters.isEmpty ? nil : ChannelEQ(filters: rightFilters)
        )
    }

    public static func create(identityKey: String, colorHex: String) -> ProfileEditorDraft {
        let profile = EQProfile.makeNew()
        let bands = (profile.linked?.filters ?? []).map { ProfileEditorBand(filter: $0) }
        return ProfileEditorDraft(
            identityKey: identityKey,
            originalFilename: nil,
            name: profile.name,
            colorHex: colorHex,
            preampDB: profile.linked?.preampDB ?? 0,
            bands: bands,
            leftBands: [],
            rightBands: [],
            hiddenFilters: [],
            hiddenLeftFilters: [],
            hiddenRightFilters: [],
            expandedBandID: bands.first?.id,
            revision: 0
        )
    }

    public static func edit(
        identityKey: String,
        filename: String,
        profile: EQProfile,
        colorHex: String
    ) -> ProfileEditorDraft {
        let both = split(profile.linked)
        let left = split(profile.left)
        let right = split(profile.right)
        return ProfileEditorDraft(
            identityKey: identityKey,
            originalFilename: filename,
            name: profile.name,
            colorHex: colorHex,
            preampDB: profile.linked?.preampDB
                ?? profile.left?.preampDB
                ?? profile.right?.preampDB
                ?? 0,
            bands: both.bands,
            leftBands: left.bands,
            rightBands: right.bands,
            hiddenFilters: both.hidden,
            hiddenLeftFilters: left.hidden,
            hiddenRightFilters: right.hidden,
            expandedBandID: nil,
            revision: 0
        )
    }

    public func bands(for channel: ProfileEditorChannel) -> [ProfileEditorBand] {
        switch channel {
        case .both: return bands
        case .left: return leftBands
        case .right: return rightBands
        }
    }

    public func channel(containing id: UUID) -> ProfileEditorChannel? {
        if bands.contains(where: { $0.id == id }) { return .both }
        if leftBands.contains(where: { $0.id == id }) { return .left }
        if rightBands.contains(where: { $0.id == id }) { return .right }
        return nil
    }

    public mutating func addPeakingBand(to channel: ProfileEditorChannel = .both) {
        let band = ProfileEditorBand(
            filter: EQFilter(enabled: true, kind: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1)
        )
        switch channel {
        case .both: bands.append(band)
        case .left: leftBands.append(band)
        case .right: rightBands.append(band)
        }
        expandedBandID = band.id
    }

    public mutating func removeBand(id: UUID) {
        bands.removeAll { $0.id == id }
        leftBands.removeAll { $0.id == id }
        rightBands.removeAll { $0.id == id }
        if expandedBandID == id {
            expandedBandID = nil
        }
    }

    public mutating func updateBand(_ id: UUID, _ mutate: (inout EQFilter) -> Void) {
        if let index = bands.firstIndex(where: { $0.id == id }) {
            mutate(&bands[index].filter)
        } else if let index = leftBands.firstIndex(where: { $0.id == id }) {
            mutate(&leftBands[index].filter)
        } else if let index = rightBands.firstIndex(where: { $0.id == id }) {
            mutate(&rightBands[index].filter)
        }
    }

    private static func split(_ channel: ChannelEQ?) -> (bands: [ProfileEditorBand], hidden: [EQFilter]) {
        var bands: [ProfileEditorBand] = []
        var hidden: [EQFilter] = []
        for filter in channel?.filters ?? [] {
            if filter.kind.isEditorKind {
                bands.append(ProfileEditorBand(filter: filter))
            } else {
                hidden.append(filter)
            }
        }
        return (bands, hidden)
    }
}
