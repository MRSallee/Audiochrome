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
}

/// Preset swatches for profile color mapping.
public enum ProfileColorPalette {
    /// Eight hues, spaced around the wheel. Menu-bar ramps are more extreme than UI/plot.
    public static let families: [ProfileColorFamily] = [
        ProfileColorFamily(
            canonical: "#EF4444", deep: "#DC2626", mid: "#EF4444", bright: "#F87171",
            menuBarLight: "#B91C1C", menuBarDark: "#FF6B6B"
        ),
        ProfileColorFamily(
            canonical: "#F97316", deep: "#EA580C", mid: "#F97316", bright: "#FB923C",
            menuBarLight: "#C2410C", menuBarDark: "#FFB020"
        ),
        ProfileColorFamily(
            canonical: "#EAB308", deep: "#CA8A04", mid: "#EAB308", bright: "#FACC15",
            menuBarLight: "#A16207", menuBarDark: "#FFE066"
        ),
        ProfileColorFamily(
            canonical: "#22C55E", deep: "#16A34A", mid: "#22C55E", bright: "#4ADE80",
            menuBarLight: "#15803D", menuBarDark: "#5EEC8A"
        ),
        ProfileColorFamily(
            canonical: "#14B8A6", deep: "#0F766E", mid: "#14B8A6", bright: "#2DD4BF",
            menuBarLight: "#0F766E", menuBarDark: "#5EEAD4"
        ),
        ProfileColorFamily(
            canonical: "#3B82F6", deep: "#2563EB", mid: "#3B82F6", bright: "#60A5FA",
            menuBarLight: "#1D4ED8", menuBarDark: "#93C5FD"
        ),
        ProfileColorFamily(
            canonical: "#8B5CF6", deep: "#7C3AED", mid: "#8B5CF6", bright: "#A78BFA",
            menuBarLight: "#6D28D9", menuBarDark: "#C4B5FD"
        ),
        ProfileColorFamily(
            canonical: "#EC4899", deep: "#DB2777", mid: "#EC4899", bright: "#F472B6",
            menuBarLight: "#BE185D", menuBarDark: "#FF7AB8"
        ),
    ]

    public static var swatches: [String] { families.map(\.canonical) }

    /// Neon (v1.2) and five-swatch jewel (v1.3) identities.
    private static let legacyCanonical: [String: String] = [
        "#FFEE33": "#EAB308",
        "#33DDFF": "#14B8A6",
        "#E666FF": "#8B5CF6",
        "#FF7733": "#F97316",
        "#33FF99": "#22C55E",
        "#F59E0B": "#EAB308",
        "#D97706": "#EAB308",
        "#FBBF24": "#EAB308",
        "#06B6D4": "#14B8A6",
        "#0E7490": "#14B8A6",
        "#22D3EE": "#14B8A6",
        "#6D28D9": "#8B5CF6",
        "#C4B5FD": "#8B5CF6",
        "#10B981": "#22C55E",
        "#047857": "#22C55E",
        "#34D399": "#22C55E",
    ]

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
