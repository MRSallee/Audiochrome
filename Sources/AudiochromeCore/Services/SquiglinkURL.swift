import Foundation

/// Share URLs for the Squiglink graph tool (`eqModel` / `eqFilters`).
public enum SquiglinkURL {
    public static let sandboxEQModel = "_EQ_Sandbox"

    /// EQ sandbox, seeded with PK / LSQ / HSQ bands when the draft has any.
    public static func editorURL(filters: [EQFilter]) -> URL {
        let shareable = filters.filter(\.kind.isEditorKind)
        var url = "https://squig.link/?eqModel=\(sandboxEQModel)"
        if !shareable.isEmpty {
            url += "&eqFilters=\(serializeFilters(shareable))"
        }
        return URL(string: url) ?? URL(string: "https://squig.link/")!
    }

    /// Squiglink v2 share encoding: ASCII `v2;disabled,typeIx,freq,q,gain;…` then base64url (no padding).
    /// Type index: PK=0, LSQ=1, HSQ=2.
    public static func serializeFilters(_ filters: [EQFilter]) -> String {
        let rows = filters.map { filter -> String in
            let disabled = filter.enabled ? 0 : 1
            let typeIx = shareTypeIndex(filter.kind)
            let freq = Int(filter.frequencyHz.rounded())
            return "\(disabled),\(typeIx),\(freq),\(ProfileWriter.formatNumber(filter.q)),\(ProfileWriter.formatNumber(filter.gainDB))"
        }
        let ascii = "v2;" + rows.joined(separator: ";")
        let base64 = Data(ascii.utf8).base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func shareTypeIndex(_ kind: EQFilter.Kind) -> Int {
        switch kind {
        case .lowShelf: return 1
        case .highShelf: return 2
        default: return 0
        }
    }
}
