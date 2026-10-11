import AppKit
import SwiftUI

/// Wordmark — Settings footer lockup.
struct AudiochromeBrandLockup: View {
    var logoHeight: CGFloat = 18
    var version: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let logo = Self.logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: logoHeight)
                    .foregroundStyle(.secondary)
            }
            if let version {
                Spacer(minLength: 0)
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(version.map { "Audiochrome \($0)" } ?? "Audiochrome")
    }

    /// Prefer Contents/Resources (copied by package-app). Do not use SPM
    /// `Bundle.module` — it fatals if the resource bundle is not at the .app root.
    private static let logoImage: NSImage? = {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "AudiochromeLogo", withExtension: "png"),
            Bundle.main.bundleURL
                .appendingPathComponent("Audiochrome_Audiochrome.bundle/AudiochromeLogo.png"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/Audiochrome_Audiochrome.bundle/AudiochromeLogo.png"),
        ]
        for url in candidates.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }()
}
