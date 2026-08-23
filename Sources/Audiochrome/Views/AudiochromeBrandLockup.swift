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

    /// Prefer Contents/Resources (copied by package-app); SPM Bundle.module is a fallback.
    private static let logoImage: NSImage? = {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "AudiochromeLogo", withExtension: "png"),
            Bundle.module.url(forResource: "AudiochromeLogo", withExtension: "png"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }()
}
