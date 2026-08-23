import AppKit
import SwiftUI

enum DetentSliderMetrics {
    static let thumbWidth: CGFloat = 20
    static let thumbHeight: CGFloat = 16
    static let thumbCorner: CGFloat = 8
    static let track: CGFloat = 4
    static let dot: CGFloat = 3
    static let labelHeight: CGFloat = 14
    /// Gap from the track’s bottom edge to the tick.
    static let trackToDots: CGFloat = 3
    static let dotsToLabels: CGFloat = 4

    static var trackTop: CGFloat { (thumbHeight - track) / 2 }
    static var trackBottom: CGFloat { trackTop + track }
    static var dotsTop: CGFloat { trackBottom + trackToDots }
    static var controlBottom: CGFloat { max(thumbHeight, dotsTop + dot) }

    static var height: CGFloat {
        controlBottom + dotsToLabels + labelHeight
    }
}

/// Discrete slider: filled track, squat thumb, ticks under the track.
/// The thumb draws last so it covers the active tick.
struct DetentSlider<T: Equatable>: View {
    let stops: [T]
    let labels: [String]
    let selection: T
    var showsFill: Bool = true
    let onSelect: (T) -> Void

    private var selectedIndex: Int {
        stops.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let count = max(stops.count, 2)
            let inset = DetentSliderMetrics.thumbWidth / 2
            let span = max(geo.size.width - DetentSliderMetrics.thumbWidth, 1)
            let step = span / CGFloat(count - 1)
            let labelWidth = max(step, 36)

            let x = { (index: Int) -> CGFloat in
                inset + CGFloat(index) * step
            }
            let dotsY = DetentSliderMetrics.dotsTop + DetentSliderMetrics.dot / 2
            let labelsY = DetentSliderMetrics.controlBottom
                + DetentSliderMetrics.dotsToLabels
                + DetentSliderMetrics.labelHeight / 2

            ZStack(alignment: .topLeading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: DetentSliderMetrics.track)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, DetentSliderMetrics.trackTop)

                if showsFill {
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(width: x(selectedIndex), height: DetentSliderMetrics.track)
                        .padding(.top, DetentSliderMetrics.trackTop)
                }

                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(index == selectedIndex ? 0.45 : 0.22))
                        .frame(width: DetentSliderMetrics.dot, height: DetentSliderMetrics.dot)
                        .position(x: x(index), y: dotsY)

                    let label = index < labels.count ? labels[index] : ""
                    if !label.isEmpty {
                        let isFirst = index == 0
                        let isLast = index == count - 1
                        Text(label)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(
                                width: labelWidth,
                                height: DetentSliderMetrics.labelHeight,
                                alignment: isFirst ? .leading : isLast ? .trailing : .center
                            )
                            .position(
                                x: isFirst
                                    ? labelWidth / 2
                                    : isLast
                                        ? geo.size.width - labelWidth / 2
                                        : x(index),
                                y: labelsY
                            )
                    }
                }

                RoundedRectangle(cornerRadius: DetentSliderMetrics.thumbCorner, style: .continuous)
                    .fill(Color.white)
                    .frame(width: DetentSliderMetrics.thumbWidth, height: DetentSliderMetrics.thumbHeight)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: DetentSliderMetrics.thumbCorner, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
                    .offset(x: CGFloat(selectedIndex) * step)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = (value.location.x - inset) / span
                        let index = Int((t * CGFloat(count - 1)).rounded())
                        let clamped = min(max(index, 0), count - 1)
                        let stop = stops[clamped]
                        if stop != selection {
                            onSelect(stop)
                        }
                    }
            )
        }
        .frame(height: DetentSliderMetrics.height)
    }
}
