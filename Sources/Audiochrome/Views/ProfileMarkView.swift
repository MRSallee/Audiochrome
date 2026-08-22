import AppKit
import AudiochromeCore
import SwiftUI

/// Same rest-state 5-bar mark as the menu-bar icon.
/// Selected: profile color plate + black/white bars.
/// Unselected: white plate with bars punched through.
struct ProfileMarkView: View {
    var colorHex: String? = nil
    var isSelected: Bool = false
    /// When false, only the white plate is drawn (No Profile).
    var showsBars: Bool = true
    var size: CGFloat = MenuChrome.listIconSize

    var body: some View {
        let selected = isSelected && colorHex != nil
        Canvas { context, canvasSize in
            let plate = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 0.5, dy: 0.5)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            if selected, let colorHex {
                context.fill(Path(ellipseIn: plate), with: .color(colorHex.asHexColor))
                if showsBars {
                    let ink = Color(nsColor: ProfileColorPalette.barInk(for: colorHex))
                    for rect in MenuBarBarsMark.barFrames(center: center) {
                        context.fill(
                            RoundedRectangle(cornerRadius: MenuBarBarsMark.barWidth / 2, style: .continuous)
                                .path(in: rect),
                            with: .color(ink)
                        )
                    }
                }
            } else if showsBars {
                var path = Path(ellipseIn: plate)
                for rect in MenuBarBarsMark.barFrames(center: center) {
                    path.addPath(
                        RoundedRectangle(cornerRadius: MenuBarBarsMark.barWidth / 2, style: .continuous)
                            .path(in: rect)
                    )
                }
                context.fill(path, with: .color(.white), style: FillStyle(eoFill: true))
            } else {
                context.fill(Path(ellipseIn: plate), with: .color(.white))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
