// Builds AppIcon.icns: the Claude Code mark in orange on a dark rounded tile.
// Usage: swift Resources/make_icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let cells: [(Int, Int, Int, Int)] = [
    (2, 0, 12, 2), (2, 2, 2, 2), (5, 2, 6, 2), (12, 2, 2, 2),
    (0, 4, 16, 2), (2, 6, 12, 2),
    (3, 8, 1, 2), (5, 8, 1, 2), (10, 8, 1, 2), (12, 8, 1, 2),
]
let orange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
let tile = NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x2F / 255, alpha: 1)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88),
                 xRadius: s * 0.2, yRadius: s * 0.2).addClip()
    tile.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()
    let unit = s * 0.72 / 16
    let ox = (s - 16 * unit) / 2
    let oy = (s - 10 * unit) / 2
    orange.setFill()
    for c in cells {
        // AppKit's origin is bottom-left, so flip the grid's y.
        NSRect(x: ox + CGFloat(c.0) * unit,
               y: oy + (10 - CGFloat(c.1) - CGFloat(c.3)) * unit,
               width: CGFloat(c.2) * unit, height: CGFloat(c.3) * unit).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = "Pace.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    let rep = draw(px)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", out]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(atPath: dir)
print("wrote \(out)")
