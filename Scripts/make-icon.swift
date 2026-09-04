// Draws the app icon: a rounded dark square with three stacked status dots.
// Usage: swift Scripts/make-icon.swift StackStatus/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func draw(pixels: Int) -> NSBitmapImageRep {
    // Draw into an explicit bitmap so the pixel size does not follow the screen's scale.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.06, dy: s * 0.06)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                              ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    let colors = [NSColor.systemGreen, NSColor.systemOrange, NSColor.systemRed]
    let dot = s * 0.16
    let gap = s * 0.06
    let total = CGFloat(colors.count) * dot + CGFloat(colors.count - 1) * gap
    var y = (s - total) / 2
    for color in colors.reversed() {
        let barRect = NSRect(x: s * 0.24, y: y, width: s * 0.52, height: dot)
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: dot / 2, yRadius: dot / 2).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: barRect.minX, y: y, width: dot, height: dot)).fill()
        y += dot + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var entries: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let rep = draw(pixels: pixels)
    let png = rep.representation(using: .png, properties: [:])!
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let json = try! JSONSerialization.data(withJSONObject: ["images": entries, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("wrote \(entries.count) icons to \(outDir)")
