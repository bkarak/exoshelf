// Draws ExoShelf's app icon, a 3.5" floppy disk with a DOS prompt on its
// label, into an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle background: a deep CRT blue.
    let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 1), NSColor(red: 0.04, green: 0.06, blue: 0.20, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // Disk body with the cut corner.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 236 * s, y: 196 * s))
    body.line(to: NSPoint(x: 788 * s, y: 196 * s))
    body.line(to: NSPoint(x: 788 * s, y: 772 * s))
    body.line(to: NSPoint(x: 740 * s, y: 828 * s))
    body.line(to: NSPoint(x: 236 * s, y: 828 * s))
    body.close()
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.10, alpha: 1)])!.draw(in: body, angle: -90)

    // Metal shutter at the top.
    let shutter = NSBezierPath(roundedRect: r(372, 640, 300, 188), xRadius: 10 * s, yRadius: 10 * s)
    NSGradient(colors: [NSColor(white: 0.86, alpha: 1), NSColor(white: 0.62, alpha: 1)])!.draw(in: shutter, angle: -90)
    NSColor(white: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(560, 672, 70, 128), xRadius: 6 * s, yRadius: 6 * s).fill()

    // Label with a prompt.
    let label = NSBezierPath(roundedRect: r(286, 236, 452, 340), xRadius: 14 * s, yRadius: 14 * s)
    NSColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1).setFill()
    label.fill()
    NSColor(red: 0.85, green: 0.30, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(rect: r(286, 520, 452, 26)).fill()
    let font = NSFont.monospacedSystemFont(ofSize: 112 * s, weight: .bold)
    let text = NSAttributedString(string: "C:\\>_", attributes: [
        .font: font,
        .foregroundColor: NSColor(red: 0.08, green: 0.12, blue: 0.30, alpha: 1),
    ])
    let ts = text.size()
    text.draw(at: NSPoint(x: (512 * s) - ts.width / 2, y: 330 * s - ts.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let png = draw(size: CGFloat(px)).representation(using: .png, properties: [:])!
    try png.write(to: out.appendingPathComponent("icon_\(name).png"))
}
