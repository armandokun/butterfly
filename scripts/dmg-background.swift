// Renders the DMG window background: arrow from Butterfly to Applications + install hint.
//   swift scripts/dmg-background.swift <out.png> <scale>
// Geometry must match scripts/dmg.sh (640×400 window, icons centered at x 170 / 470, y 190).
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let scale = CGFloat(Double(args[2]) ?? 1)
let size = CGSize(width: 640, height: 400)

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip so y grows downward, like Finder's icon positions.
ctx.translateBy(x: 0, y: size.height)
ctx.scaleBy(x: 1, y: -1)

NSGradient(
  starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
  ending: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1))!
  .draw(in: CGRect(origin: .zero, size: size), angle: 90)

// Arrow between the two icons.
let arrowColor = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.60, alpha: 1)
let y: CGFloat = 190
let shaft = NSBezierPath()
shaft.move(to: CGPoint(x: 262, y: y))
shaft.line(to: CGPoint(x: 370, y: y))
shaft.lineWidth = 6
shaft.lineCapStyle = .round
arrowColor.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: CGPoint(x: 356, y: y - 14))
head.line(to: CGPoint(x: 378, y: y))
head.line(to: CGPoint(x: 356, y: y + 14))
head.lineWidth = 6
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Hint text, drawn unflipped.
ctx.saveGState()
ctx.translateBy(x: 0, y: size.height)
ctx.scaleBy(x: 1, y: -1)
let para = NSMutableParagraphStyle()
para.alignment = .center
let title = NSAttributedString(string: "Drag Butterfly into Applications", attributes: [
  .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
  .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
  .paragraphStyle: para,
])
let subtitle = NSAttributedString(string: "Then open it from your Applications folder.", attributes: [
  .font: NSFont.systemFont(ofSize: 13),
  .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
  .paragraphStyle: para,
])
title.draw(in: CGRect(x: 0, y: size.height - 336, width: size.width, height: 26))
subtitle.draw(in: CGRect(x: 0, y: size.height - 360, width: size.width, height: 20))
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
