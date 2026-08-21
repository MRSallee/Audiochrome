import AppKit
import SwiftUI

/// 18pt plate with a 12pt disc in the middle.
/// Deselected: gray plate + label-color disc. Selected: white plate + colored disc.
struct ProfileMarkView: View {
    var accent: Color = .primary
    var isSelected: Bool = false
    /// When false, only the plate is drawn (No Profile).
    var showsDisc: Bool = true
    var size: CGFloat = MenuChrome.listIconSize
    var discSize: CGFloat = 12

    var body: some View {
        let plate = isSelected ? Color.white : Color.primary.opacity(0.14)
        // `labelColor` is the body-text ink (~#0D0D0D in light). compositingGroup
        // keeps glass vibrancy from washing the fill out further.
        let disc = isSelected ? accent : Color(nsColor: .labelColor)

        ZStack {
            Circle()
                .fill(plate)
            if showsDisc {
                Circle()
                    .fill(disc)
                    .frame(width: discSize, height: discSize)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
