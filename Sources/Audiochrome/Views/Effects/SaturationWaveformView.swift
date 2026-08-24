import AppKit
import AudiochromeCore
import SwiftUI

/// Dry markers from 20 Hz at ×2.5 so Even (2f) and Odd (3f) sit in the
/// gaps — an octave grid would put 2f on the next marker.
/// 20% THD is full plot height. 0.05% is a short but visible needle.
/// Delete with `Views/Effects`.
struct SaturationWaveformView: View {
    let settings: SaturationSettings
    let colorHex: String
    var isComparing: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        colorHex.profileColor(.curve, scheme: colorScheme)
    }

    private var dryColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.42 : 0.38)
    }

    private static let verticalInset: CGFloat = 2
    private static let peakTopInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 6
    private static let freqMinHz: Double = 20
    private static let freqMaxHz: Double = 20_000
    /// Wider than an octave so 2f / 3f do not land on another dry line.
    private static let dryStep = 2.5
    private static let dryHz: [Double] = {
        var tones: [Double] = []
        var hz = freqMinHz
        while hz < freqMaxHz {
            tones.append(hz)
            hz *= dryStep
        }
        return tones
    }()
    private static let dryLineWidth: CGFloat = 1
    private static let peakBaseWidth: CGFloat = 12
    private static let peakTipWidth: CGFloat = 4.5
    private static let strokeWidth: CGFloat = 1.25
    private static let curveBlackOverlayOpacity: Double = 0.20
    private static let gridLineWidth: CGFloat = 1
    private static let gridOpacity: Double = 0.18

    var body: some View {
        ZStack {
            gridLayer
            dryLayer
            if !isComparing {
                harmonicLayer
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous))
        .drawingGroup()
        .accessibilityLabel("Dry tones with even and odd harmonics")
    }

    private var gridLayer: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            guard plot.width > 1, plot.height > 1 else { return }
            Self.strokeGrid(&context, plot: plot, color: color)
        }
        .allowsHitTesting(false)
    }

    private var dryLayer: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            guard plot.width > 1, plot.height > 1 else { return }
            for hz in Self.dryHz {
                Self.drawDryLine(&context, plot: plot, hz: hz, color: dryColor)
            }
        }
    }

    private var harmonicLayer: some View {
        Canvas { context, size in
            let plot = Self.plotRect(in: size)
            guard plot.width > 1, plot.height > 1 else { return }
            let evenH = CGFloat(settings.even.plotNorm)
            let oddH = CGFloat(settings.odd.plotNorm)
            for hz in Self.dryHz {
                let drive = settings.bandwidth.driveGain(atHz: hz)
                guard drive > 0.04 else { continue }
                if evenH > 0 {
                    Self.drawNeedle(
                        &context,
                        plot: plot,
                        hz: hz * 2,
                        height: evenH * drive,
                        color: color
                    )
                }
                if oddH > 0 {
                    Self.drawNeedle(
                        &context,
                        plot: plot,
                        hz: hz * 3,
                        height: oddH * drive,
                        color: color
                    )
                }
            }
        }
    }

    private static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: max(0, size.width - horizontalInset * 2),
            height: max(0, size.height - verticalInset * 2)
        )
    }

    private static func x(forHz hz: Double, plot: CGRect) -> CGFloat? {
        guard hz >= freqMinHz, hz < freqMaxHz else { return nil }
        let t = log(hz / freqMinHz) / log(freqMaxHz / freqMinHz)
        return plot.minX + plot.width * CGFloat(t)
    }

    private static func drawDryLine(
        _ context: inout GraphicsContext,
        plot: CGRect,
        hz: Double,
        color: Color
    ) {
        guard let x = x(forHz: hz, plot: plot) else { return }
        var line = Path()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: dryLineWidth, lineCap: .butt))
    }

    private static func drawNeedle(
        _ context: inout GraphicsContext,
        plot: CGRect,
        hz: Double,
        height: CGFloat,
        color: Color
    ) {
        guard height > 0.01, let x = x(forHz: hz, plot: plot) else { return }
        let clamped = min(1, max(0, height))
        let maxPeakHeight = max(0, plot.maxY - peakTopInset)
        let tipY = plot.maxY - maxPeakHeight * clamped
        let baseY = plot.maxY
        let tipHalf = peakTipWidth / 2
        let baseHalf = peakBaseWidth / 2

        var glow = Path()
        glow.move(to: CGPoint(x: x - tipHalf * 1.4, y: tipY))
        glow.addLine(to: CGPoint(x: x + tipHalf * 1.4, y: tipY))
        glow.addLine(to: CGPoint(x: x + baseHalf * 1.55, y: baseY))
        glow.addLine(to: CGPoint(x: x - baseHalf * 1.55, y: baseY))
        glow.closeSubpath()
        context.fill(
            glow,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                startPoint: CGPoint(x: x, y: tipY),
                endPoint: CGPoint(x: x, y: baseY)
            )
        )

        let leftBase = CGPoint(x: x - baseHalf, y: baseY)
        let rightBase = CGPoint(x: x + baseHalf, y: baseY)
        let leftTip = CGPoint(x: x - tipHalf, y: tipY)
        let rightTip = CGPoint(x: x + tipHalf, y: tipY)

        var peak = Path()
        peak.move(to: leftTip)
        peak.addLine(to: rightTip)
        peak.addLine(to: rightBase)
        peak.addLine(to: leftBase)
        peak.closeSubpath()
        context.fill(
            peak,
            with: .linearGradient(
                Gradient(colors: [color, color.opacity(0.35)]),
                startPoint: CGPoint(x: x, y: tipY),
                endPoint: CGPoint(x: x, y: baseY)
            )
        )

        var ridge = Path()
        ridge.move(to: leftBase)
        ridge.addLine(to: leftTip)
        ridge.addLine(to: rightTip)
        ridge.addLine(to: rightBase)
        let strokeStyle = StrokeStyle(
            lineWidth: strokeWidth,
            lineCap: .butt,
            lineJoin: .round
        )
        context.stroke(ridge, with: .color(color), style: strokeStyle)
        context.stroke(
            ridge,
            with: .color(Color.black.opacity(curveBlackOverlayOpacity)),
            style: strokeStyle
        )
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
