import Foundation

enum DefaultEQProfiles {
    /// Bundled starter profiles copied into `~/Documents/Audiochrome/EQ profiles` on first launch.
    static var bundledURLs: [URL] {
        // Never touch SPM `Bundle.module` — its accessor fatals when
        // `Audiochrome.app/Audiochrome_Audiochrome.bundle` is missing (the
        // packaged-app case) or when the original build path is gone.
        let directories: [URL] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/DefaultEQProfiles", isDirectory: true),
            Bundle.main.resourceURL?
                .appendingPathComponent("DefaultEQProfiles", isDirectory: true),
            Bundle.main.bundleURL
                .appendingPathComponent(
                    "Audiochrome_Audiochrome.bundle/DefaultEQProfiles",
                    isDirectory: true
                ),
            Bundle.main.bundleURL
                .appendingPathComponent(
                    "Contents/MacOS/Audiochrome_Audiochrome.bundle/DefaultEQProfiles",
                    isDirectory: true
                ),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Audiochrome_Audiochrome.bundle/DefaultEQProfiles",
                    isDirectory: true
                ),
        ].compactMap { $0 }

        for directory in directories {
            if let urls = existingTxtURLs(in: directory), !urls.isEmpty {
                return urls.sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }
            }
        }

        let existing = (Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "DefaultEQProfiles") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing
    }

    private static func existingTxtURLs(in directory: URL) -> [URL]? {
        guard FileManager.default.fileExists(atPath: directory.path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return nil }
        let txt = urls.filter {
            $0.pathExtension.lowercased() == "txt" && FileManager.default.fileExists(atPath: $0.path)
        }
        return txt.isEmpty ? nil : txt
    }
}
