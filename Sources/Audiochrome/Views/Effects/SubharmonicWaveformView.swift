import AppKit
import AudiochromeCore
import SwiftUI

/// Amount vs log-frequency mass of the generated sub (one-pole at `subLowpassHz`).
/// Delete with `Views/Effects`.
struct SubharmonicWaveformView: View {
    let settings: SubharmonicSettings
    let colorHex: String
    var isComparing: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        colorHex.profileColor(.curve, scheme: colorScheme)
    }

    private static let verticalInset: CGFloat = 2
    private static let strokeWidth: CGFloat = 1.25
    private static let underCurveTopOpacity: Double = 0.32
    private static let curveBlackOverlayOpacity: Double = 0.20
    private static let freqMinHz: Double = 20
    private static let freqMaxHz: Double = 20_000
    private static let sampleCount = 96
    private static let gridLineWidth: CGFloat = 1
    private static let gridOpacity: Double = 0.22

    var body: some View {
        ZStack {
            if !isComparing {
                massLayer
            }
            gridLayer
        }
        .background {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous))
        .drawingGroup()
        .accessibilityLabel("Subharmonics amount across frequency")
    }

    private var massLayer: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            guard plot.width > 1, plot.height > 1 else { return }
            let shape = Self.envelope(settings: settings, plot: plot, canvasHeight: size.height)
            let strokeStyle = StrokeStyle(
                lineWidth: Self.strokeWidth,
                lineCap: .butt,
                lineJoin: .round
            )

            context.fill(
                shape.fill,
                with: .linearGradient(
                    Gradient(colors: [
                        color.opacity(Self.underCurveTopOpacity),
                        color.opacity(0),
                    ]),
                    startPoint: CGPoint(x: plot.midX, y: shape.ridgeTop),
                    endPoint: CGPoint(x: plot.midX, y: size.height)
                )
            )
            context.stroke(shape.ridge, with: .color(color), style: strokeStyle)
            context.stroke(
                shape.ridge,
                with: .color(Color.black.opacity(Self.curveBlackOverlayOpacity)),
                style: strokeStyle
            )
        }
        .drawingGroup()
    }

    private var gridLayer: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            guard plot.width > 1, plot.height > 1 else { return }
            Self.strokeGrid(&context, plot: plot, color: color)
        }
        .allowsHitTesting(false)
    }

    private static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: 0,
            y: verticalInset,
            width: max(0, size.width),
            height: max(0, size.height - verticalInset * 2)
        )
    }

    /// Amount % × the processor’s generated-sub one-pole `|H|`.
    private static func addedAmount(settings: SubharmonicSettings, hz: Double) -> Double {
        (Double(settings.amount.rawValue) / 100.0) * settings.range.lowpassGain(atHz: hz)
    }

    private static func envelope(
        settings: SubharmonicSettings,
        plot: CGRect,
        canvasHeight: CGFloat
    ) -> (fill: Path, ridge: Path, ridgeTop: CGFloat) {
        let logSpan = log(freqMaxHz / freqMinHz)
        let last = sampleCount - 1
        var tops: [CGPoint] = []
        tops.reserveCapacity(sampleCount)
        var ridgeTop = plot.maxY
        for i in 0..<sampleCount {
            let t = Double(i) / Double(last)
            let hz = freqMinHz * exp(t * logSpan)
            let amount = addedAmount(settings: settings, hz: hz)
            let x = plot.minX + plot.width * CGFloat(t)
            let y = plot.maxY - plot.height * CGFloat(amount)
            let point = CGPoint(x: x, y: min(plot.maxY, max(plot.minY, y)))
            tops.append(point)
            ridgeTop = min(ridgeTop, point.y)
        }

        var ridge = Path()
        ridge.move(to: tops[0])
        for point in tops.dropFirst() {
            ridge.addLine(to: point)
        }

        var fill = ridge
        fill.addLine(to: CGPoint(x: plot.maxX, y: canvasHeight))
        fill.addLine(to: CGPoint(x: plot.minX, y: canvasHeight))
        fill.closeSubpath()
        return (fill, ridge, ridgeTop)
    }

    private static func strokeGrid(_ context: inout GraphicsContext, plot: CGRect, color: Color) {
        let style = StrokeStyle(lineWidth: gridLineWidth, lineCap: .butt)
        let logSpan = log(freqMaxHz / freqMinHz)
        let edge: CGFloat = 0.75
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                color.opacity(0),
                color.opacity(gridOpacity),
            ]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        )

        var decade = 10.0
        while decade < freqMaxHz * 10 {
            for multiplier in 1...9 {
                let hz = Double(multiplier) * decade
                guard hz > freqMinHz, hz < freqMaxHz else { continue }
                let t = log(hz / freqMinHz) / logSpan
                let x = plot.minX + plot.width * CGFloat(t)
                guard x > plot.minX + edge, x < plot.maxX - edge else { continue }
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: shading, style: style)
            }
            decade *= 10
        }
    }
}
