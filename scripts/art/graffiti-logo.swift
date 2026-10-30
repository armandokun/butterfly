import AppKit
// Original graffiti-tag butterfly: one fast marker stroke (broad nib), drips, antenna flicks.
func cr(_ p: [CGPoint]) -> NSBezierPath {   // Catmull-Rom through points
    let b = NSBezierPath(); b.move(to: p[0])
    for i in 0..<(p.count - 1) {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        b.curve(to: p2, controlPoint1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                controlPoint2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    return b
}
let P: [(CGFloat, CGFloat)] = [
    (0.47, 0.30), (0.40, 0.18), (0.30, 0.16), (0.22, 0.24), (0.24, 0.36), (0.36, 0.44), (0.48, 0.47),   // lower-left wing
    (0.30, 0.56), (0.14, 0.70), (0.13, 0.84), (0.26, 0.88), (0.42, 0.74), (0.50, 0.52),                 // upper-left wing
    (0.58, 0.76), (0.74, 0.90), (0.88, 0.86), (0.88, 0.70), (0.70, 0.56), (0.52, 0.48),                 // upper-right wing
    (0.66, 0.40), (0.78, 0.28), (0.72, 0.16), (0.60, 0.18), (0.53, 0.32), (0.50, 0.46), (0.46, 0.60)    // lower-right wing → body flick
]
let antL = [CGPoint(x: 0.49, y: 0.58), CGPoint(x: 0.44, y: 0.82), CGPoint(x: 0.36, y: 1.00)]
let antR = [CGPoint(x: 0.51, y: 0.58), CGPoint(x: 0.58, y: 0.84), CGPoint(x: 0.68, y: 1.00)]
func draw(in r: NSRect, nib: CGFloat, color: NSColor, drips: Bool) {
    func map(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x * r.width, y: r.minY + (0.04 + p.y * 0.92) * r.height) }
    let main = cr(P.map { map(CGPoint(x: $0.0, y: $0.1)) })
    color.setStroke(); color.setFill()
    let a: CGFloat = .pi * 0.22, n = 14
    for i in 0...n {   // broad chisel nib: thin strokes offset along the nib angle
        let t = CGFloat(i) / CGFloat(n) - 0.5
        var tr = AffineTransform(translationByX: cos(a) * nib * t, byY: sin(a) * nib * t)
        let s = main.copy() as! NSBezierPath; s.transform(using: tr)
        s.lineWidth = nib * 0.35; s.lineCapStyle = .round; s.lineJoinStyle = .round; s.stroke()
        _ = tr
    }
    for ant in [antL, antR] { let b = cr(ant.map(map)); b.lineWidth = nib * 0.5; b.lineCapStyle = .round; b.stroke()
        let e = map(ant.last!); NSBezierPath(ovalIn: NSRect(x: e.x - nib * 0.45, y: e.y - nib * 0.45, width: nib * 0.9, height: nib * 0.9)).fill() }
    if drips {
        for (x, y, len) in [(0.30, 0.16, 0.10), (0.72, 0.16, 0.07)] as [(CGFloat, CGFloat, CGFloat)] {
            let top = map(CGPoint(x: x, y: y)), bot = map(CGPoint(x: x, y: y - len))
            let d = NSBezierPath(); d.move(to: top); d.line(to: bot); d.lineWidth = nib * 0.45; d.lineCapStyle = .round; d.stroke()
            NSBezierPath(ovalIn: NSRect(x: bot.x - nib * 0.4, y: bot.y - nib * 0.5, width: nib * 0.8, height: nib * 0.9)).fill()
        }
    }
}
func png(_ size: Int, _ path: String, bg: NSColor?, color: NSColor, nib: CGFloat, inset: CGFloat, drips: Bool) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let S = CGFloat(size)
    if let bg { bg.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S), xRadius: S * 0.225, yRadius: S * 0.225).fill() }
    draw(in: NSRect(x: S * inset, y: S * inset, width: S * (1 - 2 * inset), height: S * (1 - 2 * inset)), nib: nib * S, color: color, drips: drips)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview"
if mode == "preview" {
    png(512, "/tmp/g/icon.png", bg: .white, color: .black, nib: 0.045, inset: 0.18, drips: true)
    png(44, "/tmp/g/mb.png", bg: nil, color: .black, nib: 0.09, inset: 0.02, drips: false)
} else {
    let R = "Resources"
    png(1024, "\(R)/AppIcon.icon/Assets/butterfly.png", bg: nil, color: .black, nib: 0.045, inset: 0.18, drips: true)
    png(288, "\(R)/Art/mark.png", bg: nil, color: .black, nib: 0.05, inset: 0.06, drips: true)
    png(22, "\(R)/Art/menubar.png", bg: nil, color: .black, nib: 0.11, inset: 0.02, drips: false)
    png(44, "\(R)/Art/menubar@2x.png", bg: nil, color: .black, nib: 0.09, inset: 0.02, drips: false)
    for (n, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
        png(px, "\(R)/Assets.xcassets/AppIcon.appiconset/icon_\(n).png", bg: .white, color: .black, nib: px <= 64 ? 0.07 : 0.045, inset: 0.18, drips: px > 64)
    }
}
