import SwiftUI

/// Compact header cancel/save: square X plus a Save chip, same fill, small gap.
struct HeaderCommitControls: View {
    var onCancel: () -> Void
    var onSave: () -> Void

    private enum Metrics {
        static let height: CGFloat = 24
        static let closeWidth: CGFloat = 24
        static let pointDepth: CGFloat = 8
        static let gap: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let saveFillOpacity = 0.10
        static let cancelFillOpacity = 0.05
        static let iconSize: CGFloat = MenuChrome.listIconSize
        static let iconNudgeX: CGFloat = -2
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Button(action: onCancel) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Metrics.pointDepth)
                    CloseXIcon()
                        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                        .offset(x: Metrics.iconNudgeX)
                        .frame(width: Metrics.closeWidth, height: Metrics.height)
                }
                .background {
                    BackChipShape(
                        pointDepth: Metrics.pointDepth,
                        cornerRadius: Metrics.cornerRadius
                    )
                    .fill(Color.primary.opacity(Metrics.cancelFillOpacity))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("Cancel")

            Button(action: onSave) {
                Text("Save")
                    .font(MenuChrome.bodyFont)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                    .frame(width: MenuChrome.switchWidth, height: Metrics.height)
                    .background {
                        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(Metrics.saveFillOpacity))
                    }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .fixedSize()
    }
}

/// 18pt X from the provided SVG (two diagonals, round caps).
private struct CloseXIcon: View {
    var body: some View {
        CloseXShape()
            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.tertiary)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
            .accessibilityHidden(true)
    }
}

private struct CloseXShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20
        let sy = rect.height / 20
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(4.94971, 4.94979))
        path.addLine(to: pt(14.8492, 14.8493))
        path.move(to: pt(4.94971, 14.8492))
        path.addLine(to: pt(14.8492, 4.94971))
        return path
    }
}

/// Rounded chip with a pointed left edge (back-button silhouette).
private struct BackChipShape: Shape {
    var pointDepth: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let depth = min(pointDepth, rect.width / 2)
        let radius = min(cornerRadius, rect.height / 2, (rect.width - depth) / 2)
        let bodyMinX = rect.minX + depth
        let tip = CGPoint(x: rect.minX, y: rect.midY)

        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY))
        path.addLine(to: tip)
        path.closeSubpath()
        return path
    }
}
