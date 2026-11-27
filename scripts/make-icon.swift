// Renders Arbor's app icon (a white tree on a green squircle) into the asset catalog.
// Usage: swift scripts/make-icon.swift Arbor/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func render(size: Int) -> Data {
    let pixels = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with rounded corners.
    let inset = pixels * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = pixels * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.66, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.30, alpha: 1),
    ])!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // A subtle folder tab behind the tree hints "file manager".
    let tab = NSBezierPath(roundedRect: NSRect(x: body.minX + body.width * 0.17, y: body.minY + body.height * 0.17, width: body.width * 0.66, height: body.height * 0.5), xRadius: body.width * 0.05, yRadius: body.width * 0.05)
    NSColor.white.withAlphaComponent(0.14).setFill()
    tab.fill()

    let config = NSImage.SymbolConfiguration(pointSize: pixels * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let tree = NSImage(systemSymbolName: "tree.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = tree.size
        tree.draw(in: NSRect(x: (pixels - size.width) / 2, y: (pixels - size.height) / 2 + pixels * 0.01, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(size: pixels).write(to: outputDirectory.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")
