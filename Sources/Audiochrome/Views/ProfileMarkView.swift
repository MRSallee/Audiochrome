import AppKit
import AudiochromeCore
import SwiftUI

/// Same rest-state 5-bar mark as the menu-bar icon.
/// Selected: profile color plate + black/white bars.
/// Unselected: menu-style gray plate + near-black bars.
struct ProfileMarkView: View {
    var colorHex: String? = nil
    var isSelected: Bool = false
    /// When false, only the plate is drawn (No Profile).
    var showsBars: Bool = true
    var size: CGFloat = MenuChrome.listIconSize

    var body: some View {
        let selected = isSelected && colorHex != nil
        Canvas { context, canvasSize in
            let plate = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0.5, dy: 0.5)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let scale = canvasSize.width / 18
            if selected, let colorHex {
                context.fill(Path(ellipseIn: plate), with: .color(colorHex.asHexColor))
                if showsBars {
                    fillBars(&context, center: center, scale: scale, color: Color(nsColor: ProfileColorPalette.barInk(for: colorHex)))
                }
            } else {
                context.fill(Path(ellipseIn: plate), with: .color(Color(nsColor: .labelColor).opacity(0.16)))
                if showsBars {
                    fillBars(&context, center: center, scale: scale, color: Color(nsColor: .labelColor))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func fillBars(_ context: inout GraphicsContext, center: CGPoint, scale: CGFloat, color: Color) {
        for rect in MenuBarBarsMark.barFrames(center: center, scale: scale) {
            context.fill(
                RoundedRectangle(cornerRadius: rect.width / 2, style: .continuous)
                    .path(in: rect),
                with: .color(color)
            )
        }
    }
}
