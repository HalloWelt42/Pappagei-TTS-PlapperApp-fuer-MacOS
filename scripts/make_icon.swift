// App icon: the menu-bar "bird" shape, filled with a parrot-colorful
// green->blue->red gradient, on a light background.
// Usage: swift scripts/make_icon.swift out.png
import AppKit

let px: CGFloat = 1024

// Bird glyph (same symbol as the menu bar).
let config = NSImage.SymbolConfiguration(pointSize: px * 0.55, weight: .bold)
guard let symbol = NSImage(systemSymbolName: "bird", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
    FileHandle.standardError.write(Data("bird symbol unavailable\n".utf8))
    exit(1)
}
let bs = symbol.size

// Colorful bird: draw a green->blue->red gradient, then keep only the glyph shape.
let colorBird = NSImage(size: bs)
colorBird.lockFocus()
let parrot = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.80, blue: 0.30, alpha: 1),   // green
    NSColor(srgbRed: 0.16, green: 0.45, blue: 1.00, alpha: 1),   // blue
    NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // red
], atLocations: [0.0, 0.45, 0.8], colorSpace: .sRGB)!
parrot.draw(in: NSRect(origin: .zero, size: bs), angle: 0)
symbol.draw(in: NSRect(origin: .zero, size: bs), from: .zero, operation: .destinationIn, fraction: 1.0)
colorBird.unlockFocus()

// Icon canvas: rounded, light background, colorful bird centered.
let image = NSImage(size: NSSize(width: px, height: px))
image.lockFocus()
let radius = px * 0.2237
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px),
             xRadius: radius, yRadius: radius).addClip()
NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.99, blue: 1.00, alpha: 1),
           ending: NSColor(srgbRed: 0.86, green: 0.91, blue: 0.97, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: px, height: px), angle: -90)
let target = NSRect(x: (px - bs.width) / 2, y: (px - bs.height) / 2, width: bs.width, height: bs.height)
colorBird.draw(in: target)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
