import AppKit

/// Full-bleed opaque plate. Any real alpha makes Notification Center
/// draw this as a small inset glyph instead of filling the icon well.
let dest = CommandLine.arguments.dropFirst().first
    ?? "Sources/Audiochrome/Resources/AppIcon-1024.png"
let pixels = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create bitmap")
}
rep.size = NSSize(width: pixels, height: pixels)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.shouldAntialias = true

let bounds = NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
NSColor.black.setFill()
bounds.fill()

let count = 5
let barWidth: CGFloat = 2
let gap: CGFloat = 0.5
let heights: [CGFloat] = [6, 10, 12, 10, 6]
let scale = CGFloat(pixels) / 18
let width = barWidth * scale
let spacing = gap * scale
let totalWidth = CGFloat(count) * width + CGFloat(count - 1) * spacing
let center = CGPoint(x: bounds.midX, y: bounds.midY)
let firstX = center.x - totalWidth / 2

// Light-banner gray so the bars still read as knocked-out on notifications.
NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
for i in 0..<count {
    let height = heights[i] * scale
    let rect = NSRect(
        x: firstX + CGFloat(i) * (width + spacing),
        y: center.y - height / 2,
        width: width,
        height: height
    )
    NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: dest), options: .atomic)
print("Wrote \(dest) (\(png.count) bytes)")
