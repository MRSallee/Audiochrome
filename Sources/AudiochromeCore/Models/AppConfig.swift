import Foundation

public struct OutputMapping: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var profileFilename: String?
    public var colorHex: String
    /// Absolute path to this output’s EQ profile folder. `nil` = default App Support Profiles folder.
    public var profilesDirectoryPath: String?

    public init(
        enabled: Bool = false,
        profileFilename: String? = nil,
        colorHex: String = ProfileColorPalette.swatches[0],
        profilesDirectoryPath: String? = nil
    ) {
        self.enabled = enabled
        self.profileFilename = profileFilename
        self.colorHex = colorHex
        self.profilesDirectoryPath = profilesDirectoryPath
    }

    public static func defaultColorHex(for filename: String) -> String {
        let palette = ProfileColorPalette.swatches
        let hash = filename.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// A destination we've seen as the system default (or as a live Core Audio output).
public struct KnownOutput: Codable, Equatable, Sendable, Identifiable {
    public var id: String { identityKey }
    /// Stable key for mappings (AirPlay endpoint id when possible; else device UID).
    public var identityKey: String
    /// Latest Core Audio device UID (AirPlay UIDs can change between sessions).
    public var uid: String
    /// Last name reported by the system (often just "AirPlay").
    public var name: String
    /// User-chosen label (e.g. "Living Room").
    public var displayName: String?
    public var transport: String?
    public var lastSeen: Date

    public init(
        identityKey: String,
        uid: String,
        name: String,
        displayName: String? = nil,
        transport: String? = nil,
        lastSeen: Date = Date()
    ) {
        self.identityKey = identityKey
        self.uid = uid
        self.name = name
        self.displayName = displayName
        self.transport = transport
        self.lastSeen = lastSeen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        if let key = try container.decodeIfPresent(String.self, forKey: .identityKey), !key.isEmpty {
            identityKey = key
        } else {
            identityKey = DeviceIdentity.key(uid: uid, transport: transport)
        }
    }

    public var resolvedName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return name
    }

    public var needsFriendlyName: Bool {
        // True only when still showing the raw generic system label.
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty && name.caseInsensitiveCompare("AirPlay") == .orderedSame
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    /// EQ mappings keyed by identityKey.
    public var outputs: [String: OutputMapping]
    /// Remembered destinations keyed by identityKey.
    public var knownOutputs: [String: KnownOutput]
    /// Colors keyed by profile filename — color belongs to the profile, not the output.
    public var profileColors: [String: String]
    public var openAtLogin: Bool

    public init(
        outputs: [String: OutputMapping] = [:],
        knownOutputs: [String: KnownOutput] = [:],
        profileColors: [String: String] = [:],
        openAtLogin: Bool = false
    ) {
        self.outputs = outputs
        self.knownOutputs = knownOutputs
        self.profileColors = profileColors
        self.openAtLogin = openAtLogin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputs = try container.decodeIfPresent([String: OutputMapping].self, forKey: .outputs) ?? [:]
        knownOutputs = try container.decodeIfPresent([String: KnownOutput].self, forKey: .knownOutputs) ?? [:]
        profileColors = try container.decodeIfPresent([String: String].self, forKey: .profileColors) ?? [:]
        openAtLogin = try container.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false

        // Migrate legacy entries that used raw UID as the only key / lacked identityKey.
        var migratedKnown: [String: KnownOutput] = [:]
        for (key, var record) in knownOutputs {
            if record.identityKey.isEmpty {
                record.identityKey = DeviceIdentity.key(uid: record.uid, transport: record.transport)
            }
            // If dictionary key was raw uid, re-key.
            migratedKnown[record.identityKey] = record
            _ = key
        }
        knownOutputs = migratedKnown

        var migratedOutputs: [String: OutputMapping] = [:]
        for (key, mapping) in outputs {
            if let known = migratedKnown[key] {
                migratedOutputs[known.identityKey] = mapping
            } else if let known = migratedKnown.values.first(where: { $0.uid == key }) {
                migratedOutputs[known.identityKey] = mapping
            } else {
                let identity = DeviceIdentity.key(uid: key, transport: nil)
                migratedOutputs[identity] = mapping
            }
        }
        outputs = migratedOutputs

        // Seed profileColors from existing per-output colors when missing.
        for mapping in outputs.values {
            guard let filename = mapping.profileFilename, !filename.isEmpty else { continue }
            if profileColors[filename] == nil || profileColors[filename]?.isEmpty == true {
                profileColors[filename] = mapping.colorHex
            }
        }
    }

    public func colorHex(forProfile filename: String) -> String {
        if let hex = profileColors[filename]?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty {
            return hex
        }
        return OutputMapping.defaultColorHex(for: filename)
    }

    public mutating func setColorHex(_ hex: String, forProfile filename: String) {
        profileColors[filename] = hex
    }

    public func mapping(forIdentity identityKey: String) -> OutputMapping {
        outputs[identityKey] ?? OutputMapping()
    }

    public mutating func setMapping(_ mapping: OutputMapping, forIdentity identityKey: String) {
        outputs[identityKey] = mapping
    }

    public mutating func remember(_ device: AudioOutputDevice) {
        if DeviceIdentity.isInternalAudiochromeDevice(uid: device.uid, name: device.name) {
            return
        }
        let key = device.identityKey
        var record = knownOutputs[key] ?? KnownOutput(
            identityKey: key,
            uid: device.uid,
            name: device.name,
            transport: device.transport
        )
        record.uid = device.uid
        record.name = device.name
        record.transport = device.transport ?? record.transport
        record.lastSeen = Date()

        // Core Audio only reports "AirPlay" — assign a unique default label once.
        let existingLabel = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingLabel.isEmpty {
            if isAirPlayRecord(name: device.name, transport: record.transport, identityKey: key) {
                record.displayName = nextAirPlayDisplayName(excluding: key)
            }
        }

        knownOutputs[key] = record
    }

    /// Drop remembered aggregate/tap leftovers from earlier sessions.
    public mutating func purgeInternalDevices() {
        let staleKeys = knownOutputs.compactMap { key, record -> String? in
            DeviceIdentity.isInternalAudiochromeDevice(uid: record.uid, name: record.name) ? key : nil
        }
        for key in staleKeys {
            removeOutput(identityKey: key)
        }
    }

    /// "AirPlay device 1", "AirPlay device 2", … skipping names already in use.
    public func nextAirPlayDisplayName(excluding identityKey: String) -> String {
        let used = Set(
            knownOutputs
                .filter { $0.key != identityKey }
                .compactMap { $0.value.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var n = 1
        while true {
            let candidate = "AirPlay device \(n)"
            if !used.contains(candidate.lowercased()) {
                return candidate
            }
            n += 1
        }
    }

    /// Backfill unique AirPlay labels for already-remembered generic entries.
    public mutating func ensureAirPlayDisplayNames() {
        for key in knownOutputs.keys.sorted() {
            guard var record = knownOutputs[key] else { continue }
            let hasCustom = !(record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard !hasCustom else { continue }
            guard isAirPlayRecord(name: record.name, transport: record.transport, identityKey: key) else { continue }
            record.displayName = nextAirPlayDisplayName(excluding: key)
            knownOutputs[key] = record
        }
    }

    private func isAirPlayRecord(name: String, transport: String?, identityKey: String) -> Bool {
        name.caseInsensitiveCompare("AirPlay") == .orderedSame
            || transport == "AirPlay"
            || identityKey.hasPrefix("airplay:")
    }

    public mutating func setDisplayName(_ displayName: String?, forIdentity identityKey: String) {
        guard var record = knownOutputs[identityKey] else { return }
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        record.displayName = trimmed.isEmpty ? nil : trimmed
        knownOutputs[identityKey] = record
    }

    public mutating func removeOutput(identityKey: String) {
        knownOutputs.removeValue(forKey: identityKey)
        outputs.removeValue(forKey: identityKey)
    }
}

public enum DeviceIdentity {
    /// AirPlay device UIDs look like: `{uuid}-{endpointId}-Audio`
    public static func key(uid: String, transport: String?) -> String {
        if let endpoint = airPlayEndpointID(from: uid) {
            return "airplay:\(endpoint)"
        }
        if transport == "AirPlay", uid.lowercased().contains("airplay") {
            return "airplay:\(uid)"
        }
        return uid
    }

    public static func airPlayEndpointID(from uid: String) -> String? {
        // …-30127228662125-Audio
        guard uid.hasSuffix("-Audio") else { return nil }
        let body = String(uid.dropLast("-Audio".count))
        guard let lastDash = body.lastIndex(of: "-") else { return nil }
        let endpoint = String(body[body.index(after: lastDash)...])
        guard !endpoint.isEmpty, endpoint.allSatisfy(\.isNumber) else { return nil }
        return endpoint
    }

    /// Our private aggregate / tap devices — never show or remember these.
    public static func isInternalAudiochromeDevice(uid: String, name: String) -> Bool {
        if uid.hasPrefix("app.audiochrome.aggregate.") { return true }
        if name.caseInsensitiveCompare("Audiochrome") == .orderedSame { return true }
        return false
    }
}

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public var id: String { identityKey }
    public var uid: String
    public var identityKey: String
    public var name: String
    public var isDefault: Bool
    public var isAvailable: Bool
    public var transport: String?
    public var needsFriendlyName: Bool

    public init(
        uid: String,
        name: String,
        isDefault: Bool,
        isAvailable: Bool = true,
        transport: String? = nil,
        displayName: String? = nil,
        needsFriendlyName: Bool = false
    ) {
        self.uid = uid
        self.identityKey = DeviceIdentity.key(uid: uid, transport: transport)
        self.name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name
        self.isDefault = isDefault
        self.isAvailable = isAvailable
        self.transport = transport
        self.needsFriendlyName = needsFriendlyName
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
