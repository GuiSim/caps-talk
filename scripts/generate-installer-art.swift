#!/usr/bin/env swift
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/generate-installer-art.swift PROJECT_DIR signed|local\n", stderr)
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = root.appendingPathComponent("dist")
let signed = CommandLine.arguments[2] == "signed"
let teal = NSColor(srgbRed: 0.07, green: 0.30, blue: 0.29, alpha: 1)
let gray = NSColor(srgbRed: 0.32, green: 0.39, blue: 0.39, alpha: 1)
let cream = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.93, alpha: 1)

func text(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .labelColor, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    paragraph.lineSpacing = 4
    (value as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}

// A Retina Finder background with room for the actual draggable icons.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 1000,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: 660, height: 500)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
cream.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 660, height: 500)).fill()
text("Install CapsTalk", in: NSRect(x: 40, y: 412, width: 580, height: 48),
    size: 32, weight: .bold, color: teal, centered: true)
text("Hold Caps Lock to talk. Release to mute.", in: NSRect(x: 40, y: 382, width: 580, height: 30),
    size: 16, color: gray, centered: true)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 295, y: 295))
arrow.line(to: NSPoint(x: 363, y: 295))
arrow.move(to: NSPoint(x: 347, y: 312))
arrow.line(to: NSPoint(x: 365, y: 295))
arrow.line(to: NSPoint(x: 347, y: 278))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
teal.withAlphaComponent(0.65).setStroke()
arrow.stroke()
text("Drag CapsTalk to Applications", in: NSRect(x: 40, y: 190, width: 580, height: 30),
    size: 18, weight: .medium, color: teal, centered: true)
text("Then open CapsTalk from Applications.", in: NSRect(x: 40, y: 161, width: 580, height: 28),
    size: 14, color: gray, centered: true)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent("installer-background.png"))

// A native one-page PDF opens in Preview and walks users through macOS permissions.
var page = CGRect(x: 0, y: 0, width: 612, height: 792)
let consumer = CGDataConsumer(url: output.appendingPathComponent("Start Here.pdf") as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: "Install CapsTalk"] as CFDictionary)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
NSImage(contentsOf: root.appendingPathComponent("Resources/CapsTalk.png"))!
    .draw(in: NSRect(x: 42, y: 670, width: 88, height: 88))
text("CapsTalk", in: NSRect(x: 148, y: 708, width: 410, height: 44),
    size: 32, weight: .bold, color: teal)
text("Hold Caps Lock to talk. Release to mute.",
    in: NSRect(x: 148, y: 671, width: 410, height: 36), size: 14, color: gray)

func step(_ number: String, _ title: String, _ body: String, top: CGFloat, height: CGFloat) {
    teal.setFill()
    NSBezierPath(ovalIn: NSRect(x: 48, y: top - 29, width: 28, height: 28)).fill()
    text(number, in: NSRect(x: 48, y: top - 28, width: 28, height: 25), size: 16,
        weight: .bold, color: .white, centered: true)
    text(title, in: NSRect(x: 92, y: top - 31, width: 465, height: 32),
        size: 19, weight: .semibold, color: teal)
    text(body, in: NSRect(x: 92, y: top - 43 - height, width: 465, height: height), size: 13, color: gray)
}
step("1", "Drag to Applications", "In the installer window, drag the CapsTalk icon onto Applications. If you already have CapsTalk, quit it from its menu before replacing it.", top: 623, height: 66)
let opening = signed
    ? "Open Applications and double-click CapsTalk. Confirm Open if macOS asks. You will find its microphone icon in the menu bar at the top of your screen."
    : "Open Applications and double-click CapsTalk. This release has not been notarized by Apple. If macOS blocks it, open System Settings → Privacy & Security, click Open Anyway, then confirm Open. Use this option only for the official GuiSim/caps-talk download."
step("2", "Open CapsTalk", opening, top: 480, height: signed ? 76 : 111)
step("3", "Allow Accessibility access", "CapsTalk will offer to open System Settings → Privacy & Security → Accessibility. Turn on CapsTalk. If it is missing, click + and choose Applications → CapsTalk. Also allow Input Monitoring if macOS asks. CapsTalk starts automatically when access is granted.", top: 292, height: 106)
text("Ready to talk", in: NSRect(x: 48, y: 87, width: 510, height: 26),
    size: 16, weight: .semibold, color: teal)
text("Hold Caps Lock to unmute; release it to mute. Use the same microphone in your meeting app, and leave that app’s own mute off. Pausing or quitting CapsTalk restores your original microphone settings.",
    in: NSRect(x: 48, y: 23, width: 510, height: 62), size: 12, color: gray)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()
