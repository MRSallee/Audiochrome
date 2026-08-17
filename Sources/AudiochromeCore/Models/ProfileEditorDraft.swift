import Foundation

public struct ProfileEditorBand: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filter: EQFilter

    public init(id: UUID = UUID(), filter: EQFilter) {
        self.id = id
        self.filter = filter
    }
}

/// In-panel PEQ editor state. Always linked stereo for now; L/R editing comes later.
public struct ProfileEditorDraft: Equatable, Sendable {
    public var identityKey: String
    public var originalFilename: String?
    public var name: String
    public var colorHex: String
    public var preampDB: Double
    public var bands: [ProfileEditorBand]
    /// LP/HP/notch/etc. kept on save but not shown in the 2.0 UI.
    public var hiddenFilters: [EQFilter]
    public var expandedBandID: UUID?
    public var revision: Int

    public var eqProfile: EQProfile {
        EQProfile(
            name: name,
            linked: ChannelEQ(preampDB: preampDB, filters: bands.map(\.filter) + hiddenFilters)
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
            hiddenFilters: [],
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
        let channel = profile.linked ?? profile.effectiveLeft
        var bands: [ProfileEditorBand] = []
        var hidden: [EQFilter] = []
        for filter in channel.filters {
            if filter.kind.isEditorKind {
                bands.append(ProfileEditorBand(filter: filter))
            } else {
                hidden.append(filter)
            }
        }
        return ProfileEditorDraft(
            identityKey: identityKey,
            originalFilename: filename,
            name: profile.name,
            colorHex: colorHex,
            preampDB: channel.preampDB,
            bands: bands,
            hiddenFilters: hidden,
            expandedBandID: bands.first?.id,
            revision: 0
        )
    }

    public mutating func addPeakingBand() {
        let band = ProfileEditorBand(
            filter: EQFilter(enabled: true, kind: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1)
        )
        bands.append(band)
        expandedBandID = band.id
    }

    public mutating func removeBand(id: UUID) {
        bands.removeAll { $0.id == id }
        if expandedBandID == id {
            expandedBandID = bands.first?.id
        }
    }
}
