#!/usr/bin/env swift
import AppKit

// Vector artwork rendered separately at each macOS icon resolution.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = root.appendingPathComponent("CapsTalk.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
        xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.02, 0.12, 0.12, 0.25)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.05, 0.31, 0.30).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.05, 0.30, 0.29), ending: color(0.15, 0.57, 0.52))!
        .draw(in: tile, angle: 70)

    // A shallow keyboard key, with an ivory top and a warm recessed edge.
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowColor = color(0.01, 0.16, 0.16, 0.30)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -22)
    shadow.set()
    rounded(NSRect(x: 228, y: 207, width: 568, height: 596), 118, color(0.78, 0.79, 0.69))
    NSGraphicsContext.restoreGraphicsState()
    let key = NSBezierPath(roundedRect: NSRect(x: 228, y: 239, width: 568, height: 568),
        xRadius: 118, yRadius: 118)
    NSGradient(starting: color(0.92, 0.91, 0.84), ending: color(1, 0.98, 0.90))!
        .draw(in: key, angle: 90)
    color(1, 1, 1, 0.55).setStroke()
    key.lineWidth = 3
    key.stroke()

    let ink = color(0.07, 0.30, 0.29)
    rounded(NSRect(x: 445, y: 451, width: 134, height: 225), 67, ink)
    // Rounded microphone cradle and stand stay readable at 16 px.
    let cradle = NSBezierPath()
    cradle.move(to: NSPoint(x: 389, y: 527))
    cradle.line(to: NSPoint(x: 389, y: 480))
    cradle.curve(to: NSPoint(x: 512, y: 357), controlPoint1: NSPoint(x: 389, y: 412),
        controlPoint2: NSPoint(x: 444, y: 357))
    cradle.curve(to: NSPoint(x: 635, y: 480), controlPoint1: NSPoint(x: 580, y: 357),
        controlPoint2: NSPoint(x: 635, y: 412))
    cradle.line(to: NSPoint(x: 635, y: 527))
    cradle.lineWidth = 34
    cradle.lineCapStyle = .round
    ink.setStroke()
    cradle.stroke()
    rounded(NSRect(x: 495, y: 312, width: 34, height: 63), 17, ink)
    rounded(NSRect(x: 453, y: 300, width: 118, height: 32), 16, ink)

    // Caps Lock's upward arrow, kept secondary to the microphone.
    if size >= 64 {
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 303, y: 708))
        arrow.line(to: NSPoint(x: 328, y: 735))
        arrow.line(to: NSPoint(x: 353, y: 708))
        arrow.move(to: NSPoint(x: 328, y: 732))
        arrow.line(to: NSPoint(x: 328, y: 687))
        arrow.move(to: NSPoint(x: 308, y: 675))
        arrow.line(to: NSPoint(x: 348, y: 675))
        arrow.lineWidth = 9
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        ink.withAlphaComponent(0.45).setStroke()
        arrow.stroke()
    }
    color(0.94, 0.40, 0.29).setFill()
    NSBezierPath(ovalIn: NSRect(x: 684, y: 693, width: 37, height: 37)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = drawIcon(size: points * scale)
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if points == 512 && scale == 2 {
            try data.write(to: root.appendingPathComponent("CapsTalk.png"))
        }
    }
}
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("CapsTalk.icns").path]
try conversion.run()
conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else { fatalError("Icon conversion failed") }
try FileManager.default.removeItem(at: iconset)
