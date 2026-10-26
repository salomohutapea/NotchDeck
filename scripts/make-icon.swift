// Renders the 1024x1024 app icon: a dark rounded square with a notch pill and four live-activity dots.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centred in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184)
NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1), NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1)])!
    .draw(in: path, angle: -90)

// Notch: black pill hanging from the top edge of the tile.
let notch = NSRect(x: 312, y: 924 - 250, width: 400, height: 250)
let notchPath = NSBezierPath()
notchPath.move(to: NSPoint(x: notch.minX, y: notch.maxY))
notchPath.line(to: NSPoint(x: notch.maxX, y: notch.maxY))
notchPath.line(to: NSPoint(x: notch.maxX, y: notch.minY + 90))
notchPath.curve(to: NSPoint(x: notch.maxX - 90, y: notch.minY), controlPoint1: NSPoint(x: notch.maxX, y: notch.minY + 30),
                controlPoint2: NSPoint(x: notch.maxX - 30, y: notch.minY))
notchPath.line(to: NSPoint(x: notch.minX + 90, y: notch.minY))
notchPath.curve(to: NSPoint(x: notch.minX, y: notch.minY + 90), controlPoint1: NSPoint(x: notch.minX + 30, y: notch.minY),
                controlPoint2: NSPoint(x: notch.minX, y: notch.minY + 30))
notchPath.close()
NSColor.black.setFill(); notchPath.fill()

// Four icons (2 left, 2 right of the notch): music, AI, build, focus.
let colors: [NSColor] = [NSColor(red: 1.0, green: 0.35, blue: 0.45, alpha: 1), NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                         NSColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1), NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1)]
let xs: [CGFloat] = [150, 232, 742, 824]
for (i, x) in xs.enumerated() {
    colors[i].setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: 924 - 150, width: 52, height: 52)).fill()
}

// Expanded panel hint: a soft rounded card with three lines.
let card = NSRect(x: 220, y: 230, width: 584, height: 400)
NSColor(white: 1, alpha: 0.08).setFill()
NSBezierPath(roundedRect: card, xRadius: 64, yRadius: 64).fill()
for (i, w) in [440.0, 330.0, 220.0].enumerated() {
    NSColor(white: 1, alpha: i == 0 ? 0.85 : 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: 280, y: 540 - CGFloat(i) * 100, width: w, height: 36), xRadius: 18, yRadius: 18).fill()
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
