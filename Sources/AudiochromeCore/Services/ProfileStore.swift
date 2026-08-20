import Foundation

public final class ProfileStore: @unchecked Sendable {
    /// User-facing default: `~/Documents/Audiochrome/EQ profiles`.
    public let profilesDirectory: URL
    /// Bundled `.txt` profiles copied into `profilesDirectory` on first create.
    private let bundledDefaultProfiles: [URL]

    public init(
        profilesDirectory: URL? = nil,
        bundledDefaultProfiles: [URL] = []
    ) {
        if let profilesDirectory {
            self.profilesDirectory = profilesDirectory
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.profilesDirectory = documents
                .appendingPathComponent("Audiochrome", isDirectory: true)
                .appendingPathComponent("EQ profiles", isDirectory: true)
        }
        self.bundledDefaultProfiles = bundledDefaultProfiles
    }

    /// Creates the default folder and seeds bundled EQ profiles when it has no `.txt` files yet
    /// (first launch, or a prior seed that failed). Existing files are never overwritten.
    public func ensureProfilesDirectoryExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        guard listProfiles().isEmpty else { return }
        seed(from: bundledDefaultProfiles)
    }

    private func seed(from sources: [URL]) {
        let fm = FileManager.default
        for source in sources {
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = profilesDirectory.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.copyItem(at: source, to: dest)
        }
    }

    public func listProfiles() -> [ProfileFile] {
        listProfiles(in: profilesDirectory)
    }

    public func listProfiles(in directory: URL) -> [ProfileFile] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { Self.isEQProfileFile($0) }
            .map { ProfileFile(filename: $0.lastPathComponent, url: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Copies a `.txt` EQ profile into `directory` (unique name if needed) after a parse check.
    /// If the file already lives in that folder, returns it without copying.
    public func importProfile(from sourceURL: URL, into directory: URL) throws -> ProfileFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard Self.isEQProfileFile(sourceURL) else {
            throw ProfileImportError.unsupportedType
        }

        _ = try ProfileParser.parseFile(at: sourceURL)

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destDir = directory.resolvingSymlinksInPath().standardizedFileURL

        if source.deletingLastPathComponent() == destDir {
            return ProfileFile(filename: source.lastPathComponent, url: source)
        }

        let destination = Self.uniqueProfileURL(for: source.lastPathComponent, in: destDir)
        try fm.copyItem(at: source, to: destination)
        return ProfileFile(filename: destination.lastPathComponent, url: destination)
    }

    public static func isEQProfileFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "txt" else { return false }
        return name.lowercased() != "readme.txt"
    }

    /// `Name.txt`, then `Name 2.txt`, `Name 3.txt`, …
    public static func uniqueProfileURL(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(base).txt")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        var n = 2
        while true {
            candidate = directory.appendingPathComponent("\(base) \(n).txt")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    public static func sanitizedFilename(forDisplayName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New Profile" : trimmed
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).txt"
    }

    /// Writes `profile` as APO text. Overwrites `original` when the display name is unchanged.
    @discardableResult
    public func write(
        _ profile: EQProfile,
        replacing original: ProfileFile?,
        in directory: URL
    ) throws -> ProfileFile {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destDir = directory.resolvingSymlinksInPath().standardizedFileURL
        let filename = Self.sanitizedFilename(forDisplayName: profile.name)
        let text = ProfileWriter.apoText(for: profile)

        if let original {
            let originalURL = original.url.resolvingSymlinksInPath().standardizedFileURL
            let sameFolder = originalURL.deletingLastPathComponent().standardizedFileURL == destDir
            if sameFolder, original.displayName == profile.name {
                try text.write(to: originalURL, atomically: true, encoding: .utf8)
                return ProfileFile(filename: originalURL.lastPathComponent, url: originalURL)
            }
        }

        let destination = Self.uniqueProfileURL(for: filename, in: destDir)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        if let original {
            try? deleteProfileFile(at: original.url, under: destDir)
        }
        return ProfileFile(filename: destination.lastPathComponent, url: destination)
    }

    /// Moves a profile file under `directory` to the Trash.
    public func deleteProfileFile(at url: URL, under directory: URL) throws {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let dir = directory.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isEQProfileFile(file) else {
            throw ProfileImportError.unsupportedType
        }
        let parent = file.deletingLastPathComponent().standardizedFileURL
        guard parent == dir else {
            throw ProfileImportError.unsupportedType
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &resultingURL)
    }
}

public enum ProfileImportError: Error, Equatable, LocalizedError {
    case unsupportedType
    case nothingImported

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: return "Only .txt EQ profiles can be imported."
        case .nothingImported: return "No EQ profiles were imported."
        }
    }
}

public final class ConfigStore: @unchecked Sendable {
    private let fileURL: URL

    public init(rootDirectory: URL? = nil) {
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport.appendingPathComponent("Audiochrome", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("config.json")
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppConfig()
        }
        return (try? Self.decode(data)) ?? AppConfig()
    }

    public func save(_ config: AppConfig) {
        guard let data = try? Self.encode(config) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    public static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func export(_ config: AppConfig, to url: URL) throws {
        try Self.encode(config).write(to: url, options: [.atomic])
    }

    public static func load(from url: URL) throws -> AppConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigStoreError.unreadableFile
        }
        do {
            return try decode(data)
        } catch {
            throw ConfigStoreError.invalidFile
        }
    }
}

public enum ConfigStoreError: LocalizedError {
    case unreadableFile
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The configuration file could not be read."
        case .invalidFile:
            return "This file isn’t a valid Audiochrome configuration snapshot."
        }
    }
}
