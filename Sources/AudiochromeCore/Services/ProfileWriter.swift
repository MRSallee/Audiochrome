import Foundation

/// Serializes `EQProfile` to Equalizer APO / Squiglink `.txt`.
public enum ProfileWriter {
    public static func apoText(for profile: EQProfile) -> String {
        var lines: [String] = []
        if profile.isMultiChannel {
            if let left = profile.left {
                lines.append("Channel: L")
                lines.append(contentsOf: channelLines(left))
            }
            if let right = profile.right {
                if !lines.isEmpty { lines.append("") }
                lines.append("Channel: R")
                lines.append(contentsOf: channelLines(right))
            }
        } else {
            lines.append(contentsOf: channelLines(profile.linked ?? ChannelEQ()))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func channelLines(_ channel: ChannelEQ) -> [String] {
        var lines = ["Preamp: \(formatNumber(channel.preampDB)) dB"]
        for (index, filter) in channel.filters.enumerated() {
            guard let type = filter.kind.apoType else { continue }
            let on = filter.enabled ? "ON" : "OFF"
            lines.append(
                "Filter \(index + 1): \(on) \(type) Fc \(formatNumber(filter.frequencyHz)) Hz Gain \(formatNumber(filter.gainDB)) dB Q \(formatNumber(filter.q))"
            )
        }
        return lines
    }

    /// Compact APO numbers: `1`, `-2.5`, `1000`.
    public static func formatNumber(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "0" }
        if abs(value - value.rounded()) < 1e-9, abs(value) < 1e12 {
            return String(Int(value.rounded()))
        }
        var text = String(format: "%.4f", value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
