import Foundation

public enum ProfileParserError: Error, Equatable, LocalizedError {
    case emptyFile
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "Profile file is empty."
        case .unreadable: return "Profile file could not be read."
        }
    }
}

/// Parses Equalizer APO / Squiglink / AutoEQ style `.txt` profiles.
public enum ProfileParser {
    public static func parseFile(at url: URL) throws -> EQProfile {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ProfileParserError.unreadable
        }
        return try parse(text, name: (url.lastPathComponent as NSString).deletingPathExtension)
    }

    public static func parse(_ text: String, name: String) throws -> EQProfile {
        let lines = text
            .components(separatedBy: .newlines)
            .map { trimComment($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw ProfileParserError.emptyFile }

        var linked = ChannelEQ()
        var left: ChannelEQ?
        var right: ChannelEQ?
        var current: ChannelRef = .linked
        var sawChannel = false

        for line in lines {
            if let channel = parseChannel(line) {
                sawChannel = true
                current = channel
                switch channel {
                case .linked:
                    break
                case .left:
                    if left == nil { left = ChannelEQ() }
                case .right:
                    if right == nil { right = ChannelEQ() }
                }
                continue
            }

            if let preamp = parsePreamp(line) {
                switch current {
                case .linked: linked.preampDB = preamp
                case .left: left?.preampDB = preamp
                case .right: right?.preampDB = preamp
                }
                continue
            }

            if let filter = parseFilter(line) {
                switch current {
                case .linked: linked.filters.append(filter)
                case .left: left?.filters.append(filter)
                case .right: right?.filters.append(filter)
                }
                continue
            }
        }

        if sawChannel {
            return EQProfile(name: name, linked: nil, left: left, right: right)
        }
        return EQProfile(name: name, linked: linked, left: nil, right: nil)
    }

    // MARK: - Line parsers

    private enum ChannelRef {
        case linked, left, right
    }

    private static func trimComment(_ line: String) -> String {
        if let idx = line.firstIndex(of: "#") {
            return String(line[..<idx])
        }
        return line
    }

    private static func parseChannel(_ line: String) -> ChannelRef? {
        // Channel: L  /  Channel: R  /  Channel: All
        let pattern = #"^Channel:\s*(.+)$"#
        guard let match = firstMatch(pattern, in: line) else { return nil }
        let value = match.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value == "L" || value == "LEFT" { return .left }
        if value == "R" || value == "RIGHT" { return .right }
        if value == "ALL" || value == "L+R" || value == "LR" { return .linked }
        // Unknown channel tags ignored for now (future surround).
        return .linked
    }

    private static func parsePreamp(_ line: String) -> Double? {
        // Preamp: -2.8847 dB
        let pattern = #"^Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB$"#
        guard let match = firstMatch(pattern, in: line) else { return nil }
        return Double(match)
    }

    private static func parseFilter(_ line: String) -> EQFilter? {
        // Filter 1: ON PK Fc 31 Hz Gain -5.6 dB Q 0.3
        // Filter: ON PK Fc 100 Hz Gain -3.0 dB Q 1.41
        let pattern =
            #"^Filter(?:\s+\d+)?:\s*(ON|OFF)\s+([A-Za-z]+)\s+Fc\s+([+-]?\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+([+-]?\d+(?:\.\d+)?)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 6
        else { return nil }

        func group(_ i: Int) -> String {
            guard let r = Range(match.range(at: i), in: line) else { return "" }
            return String(line[r])
        }

        let enabled = group(1).uppercased() == "ON"
        let kind = EQFilter.Kind.fromAPOType(group(2))
        guard kind != .unknown,
              let freq = Double(group(3)),
              let gain = Double(group(4)),
              let q = Double(group(5))
        else { return nil }

        return EQFilter(enabled: enabled, kind: kind, frequencyHz: freq, gainDB: gain, q: q)
    }

    private static func firstMatch(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[r])
    }
}
