import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 1024, height: 1024)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
        NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 202, yRadius: 202).fill()
        NSShadow().set()
        let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 500, weight: .light))!
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: 238, y: 238, width: 548, height: 548))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
