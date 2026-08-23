import AppKit
import AudiochromeCore
import SwiftUI

/// Same 5-bar family as the menu-bar icon, inscribed for the 26pt list plate.
/// Selected: profile color plate + black/white bars.
/// Paused: dark gray plate + light bars (device toggle off).
/// Unselected: menu-style gray plate + near-black bars.
struct ProfileMarkView: View {
    var colorHex: String? = nil
    var isSelected: Bool = false
    /// When false, only the plate is drawn (No Profile).
    var showsBars: Bool = true
    /// Selected, but the device toggle is off.
    var isPaused: Bool = false
    /// White plate + label ink — same as an enabled effect mark.
    var showsOnPlate: Bool = false
    var size: CGFloat = MenuChrome.listIconSize

    var body: some View {
        let selected = isSelected && colorHex != nil
        Canvas { context, canvasSize in
            let plate = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0.5, dy: 0.5)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if isPaused, selected || showsOnPlate {
                context.fill(Path(ellipseIn: plate), with: .color(MenuChrome.pausedMarkPlate))
                if showsBars {
                    fillBars(&context, center: center, size: canvasSize.width, color: MenuChrome.pausedMarkInk)
                }
            } else if showsOnPlate {
                context.fill(Path(ellipseIn: plate), with: .color(.white))
                if showsBars {
                    fillBars(&context, center: center, size: canvasSize.width, color: Color(nsColor: .labelColor))
                }
            } else if selected, let colorHex {
                context.fill(Path(ellipseIn: plate), with: .color(colorHex.asHexColor))
                if showsBars {
                    fillBars(&context, center: center, size: canvasSize.width, color: Color(nsColor: ProfileColorPalette.barInk(for: colorHex)))
                }
            } else {
                context.fill(Path(ellipseIn: plate), with: .color(Color(nsColor: .labelColor).opacity(0.16)))
                if showsBars {
                    fillBars(&context, center: center, size: canvasSize.width, color: Color(nsColor: .labelColor))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func fillBars(_ context: inout GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        for rect in MenuBarBarsMark.listBarFrames(center: center, size: size) {
            context.fill(
                RoundedRectangle(cornerRadius: rect.width / 2, style: .continuous)
                    .path(in: rect),
                with: .color(color)
            )
        }
    }
}
