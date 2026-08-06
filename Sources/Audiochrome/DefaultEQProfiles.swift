import Foundation

enum DefaultEQProfiles {
    /// Bundled starter profiles copied into `~/Documents/Audiochrome/EQ profiles` on first launch.
    static var bundledURLs: [URL] {
        // Prefer concrete filesystem paths — SPM `Bundle.module` points at
        // `Audiochrome.app/Audiochrome_Audiochrome.bundle` (missing) or a debug build path,
        // which is unreliable inside the packaged .app.
        let directories: [URL] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/DefaultEQProfiles", isDirectory: true),
            Bundle.main.resourceURL?
                .appendingPathComponent("DefaultEQProfiles", isDirectory: true),
            Bundle.main.bundleURL
                .appendingPathComponent(
                    "Contents/MacOS/Audiochrome_Audiochrome.bundle/DefaultEQProfiles",
                    isDirectory: true
                ),
            Bundle.module.bundleURL
                .appendingPathComponent("DefaultEQProfiles", isDirectory: true),
        ].compactMap { $0 }

        for directory in directories {
            if let urls = existingTxtURLs(in: directory), !urls.isEmpty {
                return urls.sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }
            }
        }

        let bundleLookups: [[URL]] = [
            Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "DefaultEQProfiles") ?? [],
            Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: "DefaultEQProfiles") ?? [],
        ]
        for urls in bundleLookups {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { return existing }
        }
        return []
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
