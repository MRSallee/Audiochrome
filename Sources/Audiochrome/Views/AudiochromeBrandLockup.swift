import AppKit
import SwiftUI

/// Wordmark + “Premium” — shared by the menu brand band and Settings header.
struct AudiochromeBrandLockup: View {
    var logoHeight: CGFloat = 20

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
            Spacer(minLength: 0)
            Text("Premium")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .opacity(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audiochrome Premium")
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
