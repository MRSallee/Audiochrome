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
    var asHexColor: Color {
        Color(hex: self) ?? .accentColor
    }
}

/// Preset swatches for profile color mapping.
public enum ProfileColorPalette {
    public static let swatches: [String] = [
        "#FFEE33",
        "#33DDFF",
        "#E666FF",
        "#FF7733",
        "#33FF99"
    ]
}
