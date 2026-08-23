import AppKit
import SwiftUI

enum DetentSliderMetrics {
    static let thumb: CGFloat = 20
    static let track: CGFloat = 4
    static let dot: CGFloat = 3
    static let labelHeight: CGFloat = 14
    static let trackToDots: CGFloat = 8
    static let dotsToLabels: CGFloat = 4

    static var height: CGFloat {
        thumb + trackToDots + dot + dotsToLabels + labelHeight
    }
}

/// Discrete slider: filled track, thumb, dots, labels under each stop.
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
            let inset = DetentSliderMetrics.thumb / 2
            let span = max(geo.size.width - DetentSliderMetrics.thumb, 1)
            let step = span / CGFloat(count - 1)
            let labelWidth = max(step, 36)

            let x = { (index: Int) -> CGFloat in
                inset + CGFloat(index) * step
            }
            let dotsY = DetentSliderMetrics.thumb + DetentSliderMetrics.trackToDots + DetentSliderMetrics.dot / 2
            let labelsY = DetentSliderMetrics.thumb + DetentSliderMetrics.trackToDots + DetentSliderMetrics.dot
                + DetentSliderMetrics.dotsToLabels + DetentSliderMetrics.labelHeight / 2

            ZStack(alignment: .topLeading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: DetentSliderMetrics.track)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, (DetentSliderMetrics.thumb - DetentSliderMetrics.track) / 2)

                if showsFill {
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(width: x(selectedIndex), height: DetentSliderMetrics.track)
                        .padding(.top, (DetentSliderMetrics.thumb - DetentSliderMetrics.track) / 2)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: DetentSliderMetrics.thumb, height: DetentSliderMetrics.thumb)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .overlay {
                        Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
                    .offset(x: CGFloat(selectedIndex) * step)

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
