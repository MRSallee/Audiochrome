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
        morph: EQBlobMorph = .rest,
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

        let p0 = Double(morph.p0)
        let p1 = Double(morph.p1)
        let p2 = Double(morph.p2)
        let p3 = Double(morph.p3)
        let w0 = Double(morph.w0)
        let w1 = Double(morph.w1)
        let w2 = Double(morph.w2)
        let w3 = Double(morph.w3)
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps) * Double.pi * 2
            let edge =
                0.42 * w0 * sin(6 * t + p0) +
                0.28 * w1 * sin(11 * t + p1) +
                0.18 * w2 * sin(17 * t + p2) +
                0.12 * w3 * sin(3 * t + p3)
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
        morph: EQBlobMorph = .rest
    ) -> NSBezierPath {
        let pts = points(
            center: center,
            radius: radius,
            level: level,
            morph: morph,
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
        morph: EQBlobMorph = .rest
    ) -> Path {
        var path = Path()
        let pts = points(
            center: center,
            radius: radius,
            level: level,
            morph: morph,
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

/// Independent harmonic phases and mixes. Restores the logo mix when all weights are 1.
struct EQBlobMorph: Equatable {
    var p0: CGFloat = 0
    var p1: CGFloat = 0
    var p2: CGFloat = 0
    var p3: CGFloat = 0
    var w0: CGFloat = 1
    var w1: CGFloat = 1
    var w2: CGFloat = 1
    var w3: CGFloat = 1

    static let rest = EQBlobMorph()
}

/// Single motion clock for the menu-bar icon and Active Profile swatch.
@MainActor
final class EQBlobMotion: ObservableObject {
    static let shared = EQBlobMotion()

    @Published private(set) var level: CGFloat = 0
    @Published private(set) var morph = EQBlobMorph.rest

    private var envelope: CGFloat = 0
    private var mixTarget = (CGFloat(1), CGFloat(1), CGFloat(1), CGFloat(1))

    /// Slow incommensurate drift (rad/sec) — morphs the edge without spinning the whole ring.
    private static let drift: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.37, -0.23, 0.58, -0.16)
    private static let mixEase: CGFloat = 0.16
    private static let mixReturn: CGFloat = 0.025
    private static let attackKick: CGFloat = 0.05

    func reset() {
        envelope = 0
        level = 0
        morph = .rest
        mixTarget = (1, 1, 1, 1)
    }

    func tick(rawLevel: CGFloat) {
        let previous = envelope
        envelope = EQBlob.advanceEnvelope(previous: envelope, rawLevel: rawLevel)
        level = envelope

        let dt = 1 / EQBlob.animationFrameRate
        let attack = max(0, envelope - previous)

        var next = morph
        next.p0 += Self.drift.0 * dt
        next.p1 += Self.drift.1 * dt
        next.p2 += Self.drift.2 * dt
        next.p3 += Self.drift.3 * dt

        if attack > Self.attackKick {
            let kick = min(1, (attack - Self.attackKick) * 2.8)
            next.p0 += kick * CGFloat.random(in: -1.15...1.15)
            next.p1 += kick * CGFloat.random(in: -1.15...1.15)
            next.p2 += kick * CGFloat.random(in: -1.15...1.15)
            next.p3 += kick * CGFloat.random(in: -1.15...1.15)
            mixTarget = (
                CGFloat.random(in: 0.30...1.30),
                CGFloat.random(in: 0.30...1.30),
                CGFloat.random(in: 0.30...1.30),
                CGFloat.random(in: 0.30...1.30)
            )
        }

        next.w0 += (mixTarget.0 - next.w0) * Self.mixEase
        next.w1 += (mixTarget.1 - next.w1) * Self.mixEase
        next.w2 += (mixTarget.2 - next.w2) * Self.mixEase
        next.w3 += (mixTarget.3 - next.w3) * Self.mixEase

        mixTarget.0 += (1 - mixTarget.0) * Self.mixReturn
        mixTarget.1 += (1 - mixTarget.1) * Self.mixReturn
        mixTarget.2 += (1 - mixTarget.2) * Self.mixReturn
        mixTarget.3 += (1 - mixTarget.3) * Self.mixReturn

        let tau = 2 * CGFloat.pi
        next.p0 = next.p0.truncatingRemainder(dividingBy: tau)
        next.p1 = next.p1.truncatingRemainder(dividingBy: tau)
        next.p2 = next.p2.truncatingRemainder(dividingBy: tau)
        next.p3 = next.p3.truncatingRemainder(dividingBy: tau)
        morph = next
    }
}
