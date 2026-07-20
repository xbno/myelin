// Generates AppIcon.icns — a white mic glyph on a dark rounded-rect.
// Run: swift Resources/make_icon.swift   (writes Resources/AppIcon.icns)
import AppKit

let px = 1024.0
let canvas = NSImage(size: NSSize(width: px, height: px))
canvas.lockFocus()

// rounded-rect background with a subtle vertical gradient (macOS "squircle"-ish)
let inset = px * 0.085
let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: px * 0.225, yRadius: px * 0.225)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1),
])!
gradient.draw(in: bg, angle: -90)

// white mic glyph, centered, tinted white via sourceAtop
let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.52, weight: .semibold)
if let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg)
{
    let glyph = NSImage(size: base.size)
    glyph.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    glyph.unlockFocus()
    let origin = NSPoint(x: (px - base.size.width) / 2, y: (px - base.size.height) / 2)
    glyph.draw(in: NSRect(origin: origin, size: base.size))
}
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
    let master = NSBitmapImageRep(data: tiff)
else { fatalError("render failed") }

// build the .iconset then hand off to iconutil
let fm = FileManager.default
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (dim, name) in variants {
    let target = NSImage(size: NSSize(width: dim, height: dim))
    target.lockFocus()
    master.draw(in: NSRect(x: 0, y: 0, width: dim, height: dim))
    target.unlockFocus()
    let rep = NSBitmapImageRep(data: target.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent(name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! proc.run()
proc.waitUntilExit()
try? fm.removeItem(at: iconset)
print("wrote AppIcon.icns")
