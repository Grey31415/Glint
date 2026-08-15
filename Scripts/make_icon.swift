import AppKit
import CoreGraphics
import Foundation

// Builds Glint.icns from the transparent orb.
//
// The source is not square and macOS icons are, so each size is drawn onto a
// square transparent canvas, scaled to fit with a small margin. Done in
// CoreGraphics rather than sips because sips cannot pad with transparency.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make_icon.swift <source.png> <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let data = try? Data(contentsOf: sourceURL),
      let src = NSBitmapImageRep(data: data)?.cgImage else {
    FileHandle.standardError.write("could not read \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Fraction of the canvas the artwork occupies. The orb already carries its own
/// glow, so it needs less inset than a flat mark would.
let fill: CGFloat = 0.94

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let sw = CGFloat(src.width), sh = CGFloat(src.height)
    let scale = min(s * fill / sw, s * fill / sh)
    let w = sw * scale, h = sh * scale
    ctx.draw(src, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
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
print("wrote \(variants.count) sizes to \(outDir.lastPathComponent)")
