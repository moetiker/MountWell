// Renders the app icon as an .iconset (usage: swift make-icon.swift <target.iconset>)
// Motif: a snow-capped mountain against the sky. Drawn by hand, because the
// SF Symbols license does not allow symbols in app icons.
// Dimensions follow Apple's macOS icon grid: 1024 canvas, body 824 × 824, corners about 185.
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// point in the 1024 grid, y from the top
func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> NSPoint {
    NSPoint(x: x / 1024 * s, y: (1024 - y) / 1024 * s)
}

func polygon(_ points: [(CGFloat, CGFloat)], _ s: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: pt(points[0].0, points[0].1, s))
    for q in points.dropFirst() { p.line(to: pt(q.0, q.1, s)) }
    p.close()
    return p
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    // shadow below the body, as on Apple's icons
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024)
    shadow.shadowBlurRadius = s * 20 / 1024
    shadow.set()
    rgb(40, 110, 200).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()

    // sky
    NSGradient(starting: rgb(120, 200, 255), ending: rgb(30, 100, 210))!.draw(in: body, angle: -90)

    // sun
    rgb(255, 225, 120).withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: NSRect(origin: pt(640, 330, s), size: NSSize(width: s * 110 / 1024, height: s * 110 / 1024))).fill()

    // back mountain
    NSGradient(starting: rgb(110, 140, 190), ending: rgb(80, 105, 160))!
        .draw(in: polygon([(560, 925), (735, 470), (930, 925)], s), angle: -90)

    // front mountain, lit and shaded side
    rgb(52, 70, 105).setFill()
    polygon([(90, 925), (420, 330), (760, 925)], s).fill()
    rgb(38, 52, 82).setFill()
    polygon([(420, 330), (760, 925), (470, 925), (455, 560)], s).fill()

    // snow cap with jagged edge
    NSColor.white.setFill()
    polygon([(420, 330), (522, 513), (490, 490), (458, 530), (420, 485), (385, 525), (350, 495), (322, 507)], s).fill()
    rgb(215, 228, 245).setFill()
    polygon([(420, 330), (522, 513), (490, 490), (458, 530), (440, 505)], s).fill()

    // ground
    rgb(28, 40, 64).setFill()
    NSBezierPath(rect: NSRect(origin: pt(100, 924, s), size: NSSize(width: s * 824 / 1024, height: s * 0.1))).fill()

    NSGraphicsContext.restoreGraphicsState()

    // thin light border
    NSColor.white.withAlphaComponent(0.25).setStroke()
    shape.lineWidth = s * 3 / 1024
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                   ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
