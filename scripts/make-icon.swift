import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Run from the repository root: swift scripts/make-icon.swift
// An optional input path imports replacement artwork as the metadata-clean master.
// Use square artwork; any existing alpha is preserved. No source metadata is copied.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let master = root.appendingPathComponent("resources/Pastrix-master.png")
let input = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1]) : master
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
      original.width == original.height else {
    fatalError("Supply a readable square icon image.")
}

func writePNG(size: Int, to output: URL) throws {
    // An explicit generic sRGB context avoids embedding a device display profile.
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: size,
              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create icon bitmap.")
    }
    context.interpolationQuality = .high
    context.draw(original, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL,
              UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write icon bitmap.")
    }
    CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Icon write failed.") }
}

let iconset = root.appendingPathComponent("resources/Pastrix.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
if input.standardizedFileURL != master.standardizedFileURL {
    try writePNG(size: original.width, to: master)
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(size: points * scale,
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try writePNG(size: 512, to: root.appendingPathComponent("docs/assets/pastrix-icon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("resources/Pastrix.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed.") }
print("Created Pastrix.icns, iconset, and website icon with generic color metadata.")
