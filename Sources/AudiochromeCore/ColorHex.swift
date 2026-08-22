import AppKit
import SwiftUI

public extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }

        let a, r, g, b: Double
        if cleaned.count == 8 {
            a = Double((value & 0xFF00_0000) >> 24) / 255
            r = Double((value & 0x00FF_0000) >> 16) / 255
            g = Double((value & 0x0000_FF00) >> 8) / 255
            b = Double(value & 0x0000_00FF) / 255
        } else {
            a = 1
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

public extension String {
    /// Picker / default UI swatch (mid ramp).
    var asHexColor: Color {
        profileColor(.swatch, dark: false)
    }

    func profileColor(_ role: ProfileColorRole, scheme: ColorScheme) -> Color {
        profileColor(role, dark: scheme == .dark)
    }

    func profileColor(_ role: ProfileColorRole, dark: Bool) -> Color {
        Color(hex: ProfileColorPalette.hex(self, role: role, dark: dark)) ?? .accentColor
    }
}

/// Where a profile color is painted — each family has a deeper and a brighter ramp.
public enum ProfileColorRole: Sendable {
    /// Color picker chips (always the mid swatch).
    case swatch
    /// 18pt dots and switch tints in the menu / editor.
    case ui
    /// Menu-bar status item.
    case menuBar
    /// EQ curve stroke and fill.
    case curve
}

/// One hue with ramps for UI, plot, and the menu-bar icon.
public struct ProfileColorFamily: Equatable, Sendable {
    public var canonical: String
    /// Deeper — light glass and light EQ plot.
    public var deep: String
    /// Mid — picker chip.
    public var mid: String
    /// Brighter — dark glass and dark EQ plot.
    public var bright: String
    /// Extra-deep — light / washed menu bar.
    public var menuBarLight: String
    /// Extra-bright — dark wallpaper showing through the menu bar.
    public var menuBarDark: String
    /// Menu-bar bar ink on this plate (`true` = black, `false` = white).
    public var darkBars: Bool
}

/// Preset swatches for profile color mapping.
public enum ProfileColorPalette {
    /// Five neon plates (yellow, cyan, purple, orange, green).
    public static let families: [ProfileColorFamily] = [
        ProfileColorFamily(
            canonical: "#FFEE33", deep: "#E6D400", mid: "#FFEE33", bright: "#FFF566",
            menuBarLight: "#E6D400", menuBarDark: "#FFF566", darkBars: true
        ),
        ProfileColorFamily(
            canonical: "#33DDFF", deep: "#00C4E6", mid: "#33DDFF", bright: "#7AEBFF",
            menuBarLight: "#00C4E6", menuBarDark: "#7AEBFF", darkBars: true
        ),
        ProfileColorFamily(
            canonical: "#E566FF", deep: "#D14EF0", mid: "#E566FF", bright: "#EE99FF",
            menuBarLight: "#D14EF0", menuBarDark: "#EE99FF", darkBars: false
        ),
        ProfileColorFamily(
            canonical: "#FF7733", deep: "#F05A10", mid: "#FF7733", bright: "#FF9A5C",
            menuBarLight: "#F05A10", menuBarDark: "#FF9A5C", darkBars: false
        ),
        ProfileColorFamily(
            canonical: "#33FF99", deep: "#00E67A", mid: "#33FF99", bright: "#6AFFB5",
            menuBarLight: "#00E67A", menuBarDark: "#6AFFB5", darkBars: true
        ),
    ]

    public static var swatches: [String] { families.map(\.canonical) }

    /// Earlier 8-hue and alternate neon spellings.
    private static let legacyCanonical: [String: String] = [
        "#E666FF": "#E566FF",
        "#EF4444": "#FF7733",
        "#DC2626": "#FF7733",
        "#F87171": "#FF7733",
        "#B91C1C": "#FF7733",
        "#FF6B6B": "#FF7733",
        "#F97316": "#FF7733",
        "#EA580C": "#FF7733",
        "#FB923C": "#FF7733",
        "#C2410C": "#FF7733",
        "#FFB020": "#FF7733",
        "#EAB308": "#FFEE33",
        "#CA8A04": "#FFEE33",
        "#FACC15": "#FFEE33",
        "#A16207": "#FFEE33",
        "#FFE066": "#FFEE33",
        "#F59E0B": "#FFEE33",
        "#D97706": "#FFEE33",
        "#FBBF24": "#FFEE33",
        "#22C55E": "#33FF99",
        "#16A34A": "#33FF99",
        "#4ADE80": "#33FF99",
        "#15803D": "#33FF99",
        "#5EEC8A": "#33FF99",
        "#10B981": "#33FF99",
        "#047857": "#33FF99",
        "#34D399": "#33FF99",
        "#14B8A6": "#33DDFF",
        "#0F766E": "#33DDFF",
        "#2DD4BF": "#33DDFF",
        "#5EEAD4": "#33DDFF",
        "#06B6D4": "#33DDFF",
        "#0E7490": "#33DDFF",
        "#22D3EE": "#33DDFF",
        "#3B82F6": "#33DDFF",
        "#2563EB": "#33DDFF",
        "#60A5FA": "#33DDFF",
        "#1D4ED8": "#33DDFF",
        "#93C5FD": "#33DDFF",
        "#8B5CF6": "#E566FF",
        "#7C3AED": "#E566FF",
        "#A78BFA": "#E566FF",
        "#6D28D9": "#E566FF",
        "#C4B5FD": "#E566FF",
        "#EC4899": "#E566FF",
        "#DB2777": "#E566FF",
        "#F472B6": "#E566FF",
        "#BE185D": "#E566FF",
        "#FF7AB8": "#E566FF",
    ]

    public static func barInk(for hex: String) -> NSColor {
        family(for: hex).darkBars ? .black : .white
    }

    public static func canonical(_ hex: String) -> String {
        family(for: hex).canonical
    }

    public static func hex(_ stored: String, role: ProfileColorRole, dark: Bool) -> String {
        let family = family(for: stored)
        switch role {
        case .swatch:
            return family.mid
        case .ui:
            return dark ? family.bright : family.mid
        case .curve:
            return dark ? family.bright : family.deep
        case .menuBar:
            return dark ? family.menuBarDark : family.menuBarLight
        }
    }

    public static func nsColor(_ stored: String, role: ProfileColorRole, dark: Bool) -> NSColor {
        NSColor(Color(hex: hex(stored, role: role, dark: dark)) ?? .accentColor)
    }

    public static func family(for hex: String) -> ProfileColorFamily {
        let key = normalize(hex)
        let identity = legacyCanonical[key] ?? key
        if let match = families.first(where: { family in
            [family.canonical, family.deep, family.mid, family.bright, family.menuBarLight, family.menuBarDark]
                .map(normalize)
                .contains(identity)
        }) {
            return match
        }
        return families[0]
    }

    private static func normalize(_ hex: String) -> String {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        return "#\(cleaned)"
    }
}
