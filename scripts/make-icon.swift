// Draws the app icon and writes Resources/AppIcon.icns. Run from the repository root:
//   swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Rounded square inside the standard macOS icon margin.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.10, green: 0.20, blue: 0.42, alpha: 1),
               ending: NSColor(red: 0.36, green: 0.62, blue: 0.88, alpha: 1))!.draw(in: tilePath, angle: 90)
    tilePath.addClip()

    // Mountains: a far ridge, then the main peak with a snowcap.
    let far = NSBezierPath()
    far.move(to: NSPoint(x: 100 * s, y: 300 * s))
    far.line(to: NSPoint(x: 330 * s, y: 520 * s))
    far.line(to: NSPoint(x: 470 * s, y: 410 * s))
    far.line(to: NSPoint(x: 700 * s, y: 600 * s))
    far.line(to: NSPoint(x: 924 * s, y: 380 * s))
    far.line(to: NSPoint(x: 924 * s, y: 100 * s))
    far.line(to: NSPoint(x: 100 * s, y: 100 * s))
    far.close()
    NSColor(red: 0.62, green: 0.74, blue: 0.88, alpha: 1).setFill()
    far.fill()

    let peak = NSBezierPath()
    peak.move(to: NSPoint(x: 100 * s, y: 180 * s))
    peak.line(to: NSPoint(x: 480 * s, y: 640 * s))
    peak.line(to: NSPoint(x: 924 * s, y: 160 * s))
    peak.line(to: NSPoint(x: 924 * s, y: 100 * s))
    peak.line(to: NSPoint(x: 100 * s, y: 100 * s))
    peak.close()
    NSColor(red: 0.20, green: 0.30, blue: 0.48, alpha: 1).setFill()
    peak.fill()

    let cap = NSBezierPath()
    cap.move(to: NSPoint(x: 362 * s, y: 497 * s))
    cap.line(to: NSPoint(x: 480 * s, y: 640 * s))
    cap.line(to: NSPoint(x: 612 * s, y: 497 * s))
    cap.line(to: NSPoint(x: 560 * s, y: 520 * s))
    cap.line(to: NSPoint(x: 512 * s, y: 470 * s))
    cap.line(to: NSPoint(x: 460 * s, y: 525 * s))
    cap.line(to: NSPoint(x: 410 * s, y: 480 * s))
    cap.close()
    NSColor.white.setFill()
    cap.fill()

    // The notch along the top edge, with a snowflake beside it.
    let notch = NSBezierPath(roundedRect: NSRect(x: 362 * s, y: 830 * s, width: 300 * s, height: 140 * s), xRadius: 50 * s, yRadius: 50 * s)
    NSColor.black.setFill()
    notch.fill()
    if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 150 * s, weight: .semibold).applying(.init(paletteColors: [.white]))) {
        let fit = flake.size
        flake.draw(in: NSRect(x: 712 * s - fit.width / 2, y: 765 * s - fit.height / 2, width: fit.width, height: fit.height))
    }

    NSGraphicsContext.current = nil
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
