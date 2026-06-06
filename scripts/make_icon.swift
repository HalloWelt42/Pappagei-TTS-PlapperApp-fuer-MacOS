// Generates a colorful parrot app icon (1024x1024 PNG) headlessly via CoreGraphics.
// Usage: swift scripts/make_icon.swift out.png
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let px = 1024
let S = CGFloat(px)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Rounded-rect mask (macOS squircle-ish corner radius).
let radius = S * 0.2237
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// Tropical diagonal gradient (cyan -> deep blue) so the parrot pops.
let colors = [CGColor(srgbRed: 0.13, green: 0.80, blue: 0.86, alpha: 1.0),
              CGColor(srgbRed: 0.06, green: 0.42, blue: 0.80, alpha: 1.0)] as CFArray
if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
}

// Parrot glyph (color emoji) with a soft drop shadow.
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
let font = CTFontCreateWithName("Apple Color Emoji" as CFString, S * 0.58, nil)
let attr = CFAttributedStringCreate(nil, "\u{1F99C}" as CFString,
                                    [kCTFontAttributeName: font] as CFDictionary)!
let line = CTLineCreateWithAttributedString(attr)
var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
ctx.textPosition = CGPoint(x: (S - w) / 2.0, y: (S - (ascent + descent)) / 2.0 + descent)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage() else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) { exit(1) }
print("wrote \(out) (\(px)x\(px))")
