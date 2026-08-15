import AppKit
import CoreGraphics
import Foundation

// Builds an .iconset from a source image.
//
//   swift Scripts/make_icon.swift <source.png> <out.iconset> [--freeform]
//
// Default is the macOS app-icon treatment: the artwork fills a rounded square
// inset from the canvas, matching the proportions Apple uses (an 824pt body on
// a 1024pt grid, corner radius 185.4). Artwork that already carries its own
// silhouette - a cut-out with transparency - wants `--freeform` instead, which
// scales it to fit and leaves the surround clear.
//
// Done in CoreGraphics rather than sips because sips cannot pad with alpha and
// cannot mask corners.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: make_icon.swift <source.png> <out.iconset> [--freeform]\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let freeform = args.contains("--freeform")

guard let data = try? Data(contentsOf: sourceURL),
      let src = NSBitmapImageRep(data: data)?.cgImage else {
    FileHandle.standardError.write("could not read \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Apple's macOS icon grid: body 824 of 1024, corner radius 185.4 of that body.
let bodyFraction: CGFloat = 824.0 / 1024.0
let radiusFraction: CGFloat = 185.4 / 824.0
/// Free-form marks carry their own glow, so they need very little margin.
let freeformFill: CGFloat = 0.94

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let sw = CGFloat(src.width), sh = CGFloat(src.height)

    if freeform {
        let scale = min(s * freeformFill / sw, s * freeformFill / sh)
        let w = sw * scale, h = sh * scale
        ctx.draw(src, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    // Rounded-square body, with the artwork aspect-*filled* so an opaque
    // background reaches every corner instead of leaving slivers.
    let body = (s * bodyFraction).rounded()
    let origin = ((s - body) / 2).rounded()
    let bodyRect = CGRect(x: origin, y: origin, width: body, height: body)
    let radius = body * radiusFraction

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    let scale = max(body / sw, body / sh)
    let w = sw * scale, h = sh * scale
    ctx.draw(src, in: CGRect(x: bodyRect.midX - w / 2, y: bodyRect.midY - h / 2, width: w, height: h))
    ctx.restoreGState()

    return ctx.makeImage()
}

// The set macOS expects inside an .iconset.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for v in variants {
    guard let image = render(size: v.px),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed at \(v.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try? png.write(to: outDir.appendingPathComponent("\(v.name).png"))
}
print("wrote \(variants.count) sizes to \(outDir.lastPathComponent) (\(freeform ? "freeform" : "rounded square"))")
