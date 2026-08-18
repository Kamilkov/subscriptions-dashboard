// Generates the AppIcon PNGs: dark squircle + three pace-colored lane bars.
// Run: swift macos/scripts/make_icon.swift <output .appiconset dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    // Apple icon grid: content squircle inset ~10% on a transparent canvas.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))!
        .draw(in: bg, angle: -90)

    let colors = [NSColor(calibratedRed: 0.19, green: 0.75, blue: 0.36, alpha: 1),   // under
                  NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),   // on
                  NSColor(calibratedRed: 1.00, green: 0.28, blue: 0.24, alpha: 1)]   // over
    let fills: [CGFloat] = [0.40, 0.66, 0.92]
    let barH = rect.height * 0.105
    let gap = rect.height * 0.095
    let barX = rect.minX + rect.width * 0.15
    let barW = rect.width * 0.70
    var y = rect.midY + (3 * barH + 2 * gap) / 2 - barH
    for i in 0..<3 {
        NSColor(white: 1, alpha: 0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
        colors[i].setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW * fills[i], height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
        y -= barH + gap
    }
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scaleFactor in [1, 2] {
        let name = scaleFactor == 1 ? "icon_\(pt).png" : "icon_\(pt)@2x.png"
        try! render(pt * scaleFactor).write(to: outDir.appendingPathComponent(name))
        images.append(["size": "\(pt)x\(pt)", "idiom": "mac",
                       "filename": name, "scale": "\(scaleFactor)x"])
    }
}
let contents: [String: Any] = ["images": images,
                               "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(outDir.path)")
