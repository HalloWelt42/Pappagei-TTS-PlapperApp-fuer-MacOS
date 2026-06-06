// Generates the app icon: the same "bird" SF Symbol used in the menu bar,
// white on a tropical gradient. Usage: swift scripts/make_icon.swift out.png
import AppKit

let px: CGFloat = 1024

// 1) White-tinted bird glyph on a transparent canvas.
let config = NSImage.SymbolConfiguration(pointSize: px * 0.50, weight: .bold)
guard let symbol = NSImage(systemSymbolName: "bird", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
    FileHandle.standardError.write(Data("bird symbol unavailable\n".utf8))
    exit(1)
}
let bs = symbol.size
let bird = NSImage(size: bs)
bird.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: bs))
NSColor.white.setFill()
NSRect(origin: .zero, size: bs).fill(using: .sourceAtop)
bird.unlockFocus()

// 2) Rounded gradient background with the bird centered.
let image = NSImage(size: NSSize(width: px, height: px))
image.lockFocus()
let radius = px * 0.2237
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px),
             xRadius: radius, yRadius: radius).addClip()
NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.80, blue: 0.86, alpha: 1),
           ending: NSColor(srgbRed: 0.06, green: 0.42, blue: 0.80, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: px, height: px), angle: -45)
let target = NSRect(x: (px - bs.width) / 2, y: (px - bs.height) / 2, width: bs.width, height: bs.height)
bird.draw(in: target)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
