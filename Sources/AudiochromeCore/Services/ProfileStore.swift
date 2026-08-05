import Foundation

public final class ProfileStore: @unchecked Sendable {
    public let rootDirectory: URL
    public var profilesDirectory: URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootDirectory = appSupport.appendingPathComponent("Audiochrome", isDirectory: true)
        }
    }

    public func ensureProfilesDirectoryExists() {
        try? FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        seedReadmeIfNeeded()
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
            .filter { $0.pathExtension.lowercased() == "txt" }
            .filter { $0.lastPathComponent.lowercased() != "readme.txt" }
            .map { ProfileFile(filename: $0.lastPathComponent, url: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func seedReadmeIfNeeded() {
        let readme = profilesDirectory.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let text = """
        Drop Equalizer APO / Squiglink / AutoEQ .txt profiles in this folder.
        Audiochrome lists .txt files from each output’s profile folder in the menu bar.

        By default every output uses this folder. Use “Change folder…” on an output to
        point it at another directory (for example Downloads/MacBook Air Speakers).

        Supported:
        - Linked stereo (Preamp + Filter lines)
        - Independent L/R (Channel: L / Channel: R sections)
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
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
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
