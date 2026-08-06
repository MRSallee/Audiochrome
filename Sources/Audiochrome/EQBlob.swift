import AppKit
import SwiftUI

/// Shared brand mark: solid inner circle + animated outer ring with a clear gap between them.
enum EQBlob {
    /// Inner disc radius as a fraction of the outer ring’s nominal radius.
    static let innerRadiusFraction: CGFloat = 0.55
    /// Stroke width as a fraction of outer radius (keeps a visible gap at 18pt).
    static let ringStrokeFraction: CGFloat = 0.16

    /// Phase advance (radians/sec) — original pace; shared by menu-bar + Active Profile.
    private static let phaseRateBase: CGFloat = 3.6
    private static let phaseRateFromLevel: CGFloat = 16.5
    static let animationFrameRate: CGFloat = 30

    /// Ignore steady low-level audio; only the part above this drives the ring.
    private static let reactivityFloor: CGFloat = 0.32
    /// Peak emphasis after gating (higher → calmer on mid levels, punchier on beats).
    private static let reactivityGamma: CGFloat = 2.4
    private static let envelopeAttack: CGFloat = 0.62
    private static let envelopeRelease: CGFloat = 0.11

    static func phaseRate(level: CGFloat) -> CGFloat {
        let amount = max(0, min(1, level))
        return phaseRateBase + amount * phaseRateFromLevel
    }

    static func phaseStep(level: CGFloat) -> CGFloat {
        phaseRate(level: level) / animationFrameRate
    }

    /// Map raw meter 0…1 → ring reactivity. Quiet/sustain ≈ 0; beats punch up.
    static func reactivity(from rawLevel: CGFloat) -> CGFloat {
        let x = max(0, min(1, rawLevel))
        let floor = reactivityFloor
        guard x > floor else { return 0 }
        let gated = (x - floor) / (1 - floor)
        return pow(gated, reactivityGamma)
    }

    /// Fast attack / slower release so hits bloom then settle back to a circle.
    static func advanceEnvelope(previous: CGFloat, rawLevel: CGFloat) -> CGFloat {
        let target = reactivity(from: rawLevel)
        let coeff = target > previous ? envelopeAttack : envelopeRelease
        var next = previous + (target - previous) * coeff
        if next < 0.012 { next = 0 }
        return min(1, next)
    }

    static func innerRadius(outerRadius: CGFloat) -> CGFloat {
        outerRadius * innerRadiusFraction
    }

    static func ringLineWidth(outerRadius: CGFloat) -> CGFloat {
        max(1.0, outerRadius * ringStrokeFraction)
    }

    /// Sampled outer ring perimeter. `level` 0 → circle; higher → logo-like irregular edge.
    /// - Parameter yIncreasesUpward: AppKit image coords are y-up; SwiftUI Canvas is y-down.
    ///   Flipping the Y offset keeps clockwise phase motion looking the same in both.
    static func points(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat,
        steps: Int = 72,
        yIncreasesUpward: Bool = true
    ) -> [CGPoint] {
        let amount = max(0, min(1, level))
        let wobble = amount < 0.04 ? 0 : amount
        let ySign: CGFloat = yIncreasesUpward ? 1 : -1

        if wobble < 0.001 {
            return (0...steps).map { i in
                let t = Double(i) / Double(steps) * Double.pi * 2
                return CGPoint(
                    x: center.x + CGFloat(cos(t) * radius),
                    y: center.y + ySign * CGFloat(sin(t) * radius)
                )
            }
        }

        let p = Double(phase)
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps) * Double.pi * 2
            let edge =
                0.42 * sin(6 * t + p) +
                0.28 * sin(11 * t - p * 1.4) +
                0.18 * sin(17 * t + p * 0.6) +
                0.12 * sin(3 * t + p * 2.2)
            let r = radius * (1 + Double(wobble) * 0.32 * edge)
            result.append(CGPoint(
                x: center.x + CGFloat(cos(t) * r),
                y: center.y + ySign * CGFloat(sin(t) * r)
            ))
        }
        return result
    }

    /// Outer ring path for AppKit (stroke this; do not fill).
    static func bezierPath(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat
    ) -> NSBezierPath {
        let pts = points(
            center: center,
            radius: radius,
            level: level,
            phase: phase,
            yIncreasesUpward: true
        )
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() {
            path.line(to: point)
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        return path
    }

    /// Outer ring path for SwiftUI Canvas (stroke this; do not fill).
    static func swiftUIPath(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat
    ) -> Path {
        var path = Path()
        let pts = points(
            center: center,
            radius: radius,
            level: level,
            phase: phase,
            yIncreasesUpward: false
        )
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func innerCircleRect(center: CGPoint, outerRadius: CGFloat) -> CGRect {
        let r = innerRadius(outerRadius: outerRadius)
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }
}

/// Single motion clock for the menu-bar icon and Active Profile swatch.
@MainActor
final class EQBlobMotion: ObservableObject {
    static let shared = EQBlobMotion()

    @Published private(set) var level: CGFloat = 0
    @Published private(set) var phase: CGFloat = 0

    private var envelope: CGFloat = 0

    func reset() {
        envelope = 0
        level = 0
        phase = 0
    }

    func tick(rawLevel: CGFloat) {
        envelope = EQBlob.advanceEnvelope(previous: envelope, rawLevel: rawLevel)
        level = envelope
        phase += EQBlob.phaseStep(level: envelope)
    }
}
