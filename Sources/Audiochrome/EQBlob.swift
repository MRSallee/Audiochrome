import AppKit
import SwiftUI

/// Shared organic blob used by the menu-bar status icon and the Active Profile swatch.
enum EQBlob {
    /// Sampled perimeter. `level` 0 → circle; higher → logo-like irregular edge.
    static func points(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat,
        steps: Int = 72
    ) -> [CGPoint] {
        let amount = max(0, min(1, level))
        let wobble = amount < 0.04 ? 0 : amount

        if wobble < 0.001 {
            // Approximate circle with same step count for stable drawing.
            return (0...steps).map { i in
                let t = Double(i) / Double(steps) * Double.pi * 2
                return CGPoint(
                    x: center.x + CGFloat(cos(t) * radius),
                    y: center.y + CGFloat(sin(t) * radius)
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
                y: center.y + CGFloat(sin(t) * r)
            ))
        }
        return result
    }

    static func bezierPath(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat
    ) -> NSBezierPath {
        let pts = points(center: center, radius: radius, level: level, phase: phase)
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() {
            path.line(to: point)
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    static func swiftUIPath(
        center: CGPoint,
        radius: CGFloat,
        level: CGFloat,
        phase: CGFloat
    ) -> Path {
        var path = Path()
        let pts = points(center: center, radius: radius, level: level, phase: phase)
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
