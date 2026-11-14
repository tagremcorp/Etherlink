// Renders the EtherLink app icon (two screens joined by an Ethernet cable) to a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: 824-point body inset 100 points, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1D4ED8).setFill(); bodyPath.fill()
ctx.restoreGState()
ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [color(0x0EA5E9), color(0x2563EB), color(0x1E3A8A)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -60)
// Subtle top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
ctx.restoreGState()

// Two screens.
func screen(centerX: CGFloat) {
    let frame = NSRect(x: centerX - 150, y: 470, width: 300, height: 215)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    color(0xF8FAFC).setFill(); NSBezierPath(roundedRect: frame, xRadius: 26, yRadius: 26).fill()
    ctx.restoreGState()
    let glass = frame.insetBy(dx: 20, dy: 20)
    NSGradient(colors: [color(0x1E293B), color(0x0F172A)])!.draw(in: NSBezierPath(roundedRect: glass, xRadius: 10, yRadius: 10), angle: -90)
    // Stand.
    color(0xE2E8F0).setFill()
    NSBezierPath(rect: NSRect(x: centerX - 22, y: 420, width: 44, height: 52)).fill()
    NSBezierPath(roundedRect: NSRect(x: centerX - 75, y: 404, width: 150, height: 26), xRadius: 13, yRadius: 13).fill()
}
screen(centerX: 330)
screen(centerX: 694)

// Shared cursor hint on the left screen, keyboard glyph lines on the right.
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 300, y: 640)); cursor.line(to: NSPoint(x: 300, y: 545)); cursor.line(to: NSPoint(x: 324, y: 568))
cursor.line(to: NSPoint(x: 342, y: 532)); cursor.line(to: NSPoint(x: 358, y: 540)); cursor.line(to: NSPoint(x: 340, y: 575))
cursor.line(to: NSPoint(x: 372, y: 575)); cursor.close()
color(0x38BDF8).setFill(); cursor.fill()
color(0x38BDF8).setFill()
for row in 0..<3 {
    for col in 0..<5 {
        NSBezierPath(roundedRect: NSRect(x: 610 + CGFloat(col) * 36, y: 610 - CGFloat(row) * 34, width: 26, height: 22), xRadius: 5, yRadius: 5).fill()
    }
}

// Cable from each stand down to a central Ethernet plug.
let cable = NSBezierPath()
cable.lineWidth = 26; cable.lineCapStyle = .round
cable.move(to: NSPoint(x: 330, y: 404)); cable.curve(to: NSPoint(x: 452, y: 268), controlPoint1: NSPoint(x: 330, y: 300), controlPoint2: NSPoint(x: 390, y: 268))
cable.move(to: NSPoint(x: 694, y: 404)); cable.curve(to: NSPoint(x: 572, y: 268), controlPoint1: NSPoint(x: 694, y: 300), controlPoint2: NSPoint(x: 634, y: 268))
color(0xF8FAFC).setStroke(); cable.stroke()

// RJ45-style plug.
let plug = NSRect(x: 432, y: 200, width: 160, height: 136)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.3).cgColor)
color(0xF8FAFC).setFill(); NSBezierPath(roundedRect: plug, xRadius: 20, yRadius: 20).fill()
ctx.restoreGState()
color(0xFBBF24).setFill()
for i in 0..<6 { NSBezierPath(roundedRect: NSRect(x: 452 + CGFloat(i) * 21, y: 290, width: 12, height: 32), xRadius: 3, yRadius: 3).fill() }
color(0x1E3A8A).setFill(); NSBezierPath(roundedRect: NSRect(x: 482, y: 222, width: 60, height: 40), xRadius: 8, yRadius: 8).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
