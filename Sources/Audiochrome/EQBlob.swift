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

    /// Ignore true quiet; keep typical listening levels in the pulse.
    private static let reactivityFloor: CGFloat = 0.10
    /// Peak emphasis after gating (higher → calmer on mid levels, punchier on beats).
    private static let reactivityGamma: CGFloat = 1.65
    private static let envelopeAttack: CGFloat = 0.55
    private static let envelopeRelease: CGFloat = 0.13
    /// Slow baseline tracks sustained loudness so busy mixes don’t pin the disc at max.
    private static let baselineFollow: CGFloat = 0.042
    /// How hard excess-above-baseline is amplified into 0…1 pulse.
    private static let punchGain: CGFloat = 2.2
    /// Mild rising-edge boost (kept low — high values read as twitch).
    private static let onsetGain: CGFloat = 1.35
    private static let onsetFloor: CGFloat = 0.035
    /// Final display smoother — quick enough for beats, soft enough to kill jitter.
    private static let displayAttack: CGFloat = 0.42
    private static let displayRelease: CGFloat = 0.16

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

    /// Fast attack / slower release so hits bloom then settle.
    static func advanceEnvelope(previous: CGFloat, rawLevel: CGFloat) -> CGFloat {
        let target = reactivity(from: rawLevel)
        let coeff = target > previous ? envelopeAttack : envelopeRelease
        var next = previous + (target - previous) * coeff
        if next < 0.012 { next = 0 }
        return min(1, next)
    }

    /// Beat / voice pulse: expand on transients above the local loudness floor.
    /// Sustained busy sections raise the baseline, so the disc keeps dipping between hits
    /// instead of sitting at max.
    /// - Returns: display-smoothed punch, unsmoothed pulse, and rising-edge onset
    ///   (onset must be read before display smoothing or kicks never fire).
    static func advanceBeatPulse(
        fast: inout CGFloat,
        baseline: inout CGFloat,
        previousFast: inout CGFloat,
        display: inout CGFloat,
        rawLevel: CGFloat
    ) -> (display: CGFloat, pulse: CGFloat, onset: CGFloat) {
        let nextFast = advanceEnvelope(previous: fast, rawLevel: rawLevel)
        baseline += (nextFast - baseline) * baselineFollow
        if baseline < 0 { baseline = 0 }

        let excess = max(0, nextFast - baseline)
        let headroom = max(0.14, 1 - baseline * 0.7)
        var pulse = min(1, (excess / headroom) * punchGain)

        let onset = max(0, nextFast - previousFast)
        if onset > onsetFloor {
            pulse = min(1, pulse + onset * onsetGain)
        }

        previousFast = nextFast
        fast = nextFast
        if pulse < 0.025 { pulse = 0 }

        let coeff = pulse > display ? displayAttack : displayRelease
        display += (pulse - display) * coeff
        if display < 0.02 { display = 0 }
        return (min(1, display), pulse, onset)
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
        yIncreasesUpward: Bool = true,
        /// How far the edge can deviate (0.32 ≈ old ring; ~0.55+ reads as Texture blob).
        edgeAmplitude: CGFloat = 0.32
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
                0.36 * w0 * sin(5 * t + p0) +
                0.24 * w1 * sin(11 * t + p1) +
                0.18 * w2 * sin(19 * t + p2) +
                0.12 * w3 * sin(3 * t + p3) +
                0.10 * sin(31 * t + p0 * 1.4) +
                0.08 * sin(47 * t + p2 * 0.7)
            let r = radius * (1 + Double(wobble) * Double(edgeAmplitude) * edge)
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

    /// Filled organic disc for AppKit (ripple color / hole).
    static func filledBezierPath(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        morph: EQBlobMorph = .rest,
        edgeAmplitude: CGFloat = 0.55
    ) -> NSBezierPath {
        let pts = points(
            center: center,
            radius: radius,
            level: level,
            morph: morph,
            yIncreasesUpward: true,
            edgeAmplitude: edgeAmplitude
        )
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() {
            path.line(to: point)
        }
        path.close()
        return path
    }

    static func innerCircleRect(center: CGPoint, outerRadius: CGFloat) -> CGRect {
        let r = innerRadius(outerRadius: outerRadius)
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    /// Plate → stroke and stroke → disc share the same gap; stroke is relatively thick.
    struct MarkLayout: Equatable {
        var plateRadius: CGFloat
        /// Stroke centerline radius.
        var ringRadius: CGFloat
        var ringWidth: CGFloat
        var innerRadius: CGFloat

        var innerRect: CGRect {
            CGRect(
                x: -innerRadius,
                y: -innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
        }
    }

    static func markLayout(plateRadius: CGFloat) -> MarkLayout {
        // Spec at 18pt plate: stroke outer 14×14, width 2, inner 6×6.
        let scale = max(1, plateRadius) / 9
        let strokeOuter = 7 * scale
        let stroke = 2 * scale
        let disc = 3 * scale
        let ringCenter = strokeOuter - stroke / 2
        return MarkLayout(
            plateRadius: plateRadius,
            ringRadius: ringCenter,
            ringWidth: stroke,
            innerRadius: disc
        )
    }

    /// Stroke centerline radius for a mark inside a plate (animation path).
    static func markOuterRadius(plateRadius: CGFloat) -> CGFloat {
        markLayout(plateRadius: plateRadius).ringRadius
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

/// Single motion clock for the menu-bar icon.
@MainActor
final class EQBlobMotion: ObservableObject {
    static let shared = EQBlobMotion()

    /// Beat detector strength 0…1 (for presence / triggers).
    @Published private(set) var level: CGFloat = 0
    /// Disc radius in points: idle 6 (12pt), dip 3 (6pt), peak 7 (14pt).
    @Published private(set) var discRadius: CGFloat = 6

    private var fast: CGFloat = 0
    private var baseline: CGFloat = 0
    private var previousFast: CGFloat = 0
    private var display: CGFloat = 0
    /// Ungated loudness follow — punch-above-baseline is ~0 on compressed music.
    private var follow: CGFloat = 0
    private var phase: CGFloat = 0
    private var beating = false
    private var beatT: CGFloat = 0

    /// 12pt / 6pt / 14pt diameters → radii.
    private static let restRadius: CGFloat = 6
    private static let dipRadius: CGFloat = 3
    private static let peakRadius: CGFloat = 7

    private static let beatDuration: CGFloat = 0.72
    /// Fraction of the beat: expand, then contract, then settle at 12pt.
    private static let peakEnd: CGFloat = 0.28
    private static let dipEnd: CGFloat = 0.62

    private static let triggerOnset: CGFloat = 0.05
    private static let triggerLevel: CGFloat = 0.12
    /// Don’t retrigger until well into the settle phase.
    private static let retriggerAfter: CGFloat = 0.7
    /// Slow idle pulse — the shared ring phaseRate is too busy for a solid disc.
    private static let breatheRateBase: CGFloat = 1.15
    private static let breatheRateFromLevel: CGFloat = 2.4

    func reset() {
        fast = 0
        baseline = 0
        previousFast = 0
        display = 0
        follow = 0
        phase = 0
        beating = false
        beatT = 0
        level = 0
        discRadius = Self.restRadius
    }

    func tick(rawLevel: CGFloat) {
        let (punch, pulse, onset) = EQBlob.advanceBeatPulse(
            fast: &fast,
            baseline: &baseline,
            previousFast: &previousFast,
            display: &display,
            rawLevel: rawLevel
        )
        level = punch

        // Drive size from the meter itself. Punch is excess-above-baseline and
        // goes to 0 on loud, even mixes — which is most streaming music.
        let target = min(1, max(0, rawLevel))
        follow += (target - follow) * (target > follow ? 0.16 : 0.07)
        if follow < 0.01 { follow = 0 }

        let audible = follow > 0.03 || rawLevel > 0.04
        let canTrigger = audible && onset > Self.triggerOnset && pulse > Self.triggerLevel
        if canTrigger, !beating || beatT >= Self.retriggerAfter {
            beating = true
            beatT = 0
        }

        let dt = 1 / EQBlob.animationFrameRate
        if beating {
            beatT += dt / Self.beatDuration
            if beatT >= 1 {
                beating = false
                beatT = 0
                discRadius = Self.livingRadius(follow: follow, phase: &phase)
            } else {
                discRadius = Self.radius(at: beatT)
            }
        } else if audible {
            discRadius = Self.livingRadius(follow: follow, phase: &phase)
        } else {
            phase = 0
            discRadius = Self.restRadius
        }
    }

    /// Loudness sets the center size; phase keeps it moving when the meter is flat.
    private static func livingRadius(follow: CGFloat, phase: inout CGFloat) -> CGFloat {
        let x = min(1, max(0, follow))
        let rate = breatheRateBase + x * breatheRateFromLevel
        phase += rate / EQBlob.animationFrameRate
        if phase > .pi * 2 { phase -= .pi * 2 }
        let center = 4.8 + x * 2.0
        let wobble = sin(phase) * (0.22 + x * 0.38)
        return center + wobble
    }

    /// 12 → 14 → 6 → 12 over one beat.
    private static func radius(at t: CGFloat) -> CGFloat {
        if t < peakEnd {
            let u = easeOut(t / peakEnd)
            return restRadius + (peakRadius - restRadius) * u
        }
        if t < dipEnd {
            let u = easeInOut((t - peakEnd) / (dipEnd - peakEnd))
            return peakRadius + (dipRadius - peakRadius) * u
        }
        let u = easeInOut((t - dipEnd) / (1 - dipEnd))
        return dipRadius + (restRadius - dipRadius) * u
    }

    private static func easeOut(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return 1 - (1 - x) * (1 - x)
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }
}
