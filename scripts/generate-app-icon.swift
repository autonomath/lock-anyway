#!/usr/bin/env swift
import AppKit
import Foundation

let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = repoURL.appendingPathComponent(".build/AppIcon.iconset")
let outputURL = repoURL.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

struct IconSize {
    let points: Int
    let scale: Int

    var pixels: Int {
        points * scale
    }

    var fileName: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    }
}

let sizes = [
    IconSize(points: 16, scale: 1),
    IconSize(points: 16, scale: 2),
    IconSize(points: 32, scale: 1),
    IconSize(points: 32, scale: 2),
    IconSize(points: 128, scale: 1),
    IconSize(points: 128, scale: 2),
    IconSize(points: 256, scale: 1),
    IconSize(points: 256, scale: 2),
    IconSize(points: 512, scale: 1),
    IconSize(points: 512, scale: 2)
]

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024.0
    let corner = 220 * scale

    NSColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()

    let gradientPath = NSBezierPath(
        roundedRect: rect.insetBy(dx: 46 * scale, dy: 46 * scale),
        xRadius: 180 * scale,
        yRadius: 180 * scale
    )
    let gradient = NSGradient(colors: [
        NSColor(red: 0.10, green: 0.24, blue: 0.48, alpha: 1),
        NSColor(red: 0.03, green: 0.12, blue: 0.28, alpha: 1)
    ])
    gradient?.draw(in: gradientPath, angle: 90)

    NSColor(red: 0.92, green: 0.74, blue: 0.36, alpha: 1).setStroke()
    let shackle = NSBezierPath()
    shackle.lineWidth = 72 * scale
    shackle.lineCapStyle = .round
    shackle.move(to: NSPoint(x: 316 * scale, y: 500 * scale))
    shackle.curve(
        to: NSPoint(x: 708 * scale, y: 500 * scale),
        controlPoint1: NSPoint(x: 316 * scale, y: 776 * scale),
        controlPoint2: NSPoint(x: 708 * scale, y: 776 * scale)
    )
    shackle.stroke()

    let bodyRect = NSRect(x: 248 * scale, y: 250 * scale, width: 528 * scale, height: 380 * scale)
    NSColor(red: 0.98, green: 0.82, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(roundedRect: bodyRect, xRadius: 64 * scale, yRadius: 64 * scale).fill()

    NSColor(red: 0.83, green: 0.58, blue: 0.16, alpha: 1).setStroke()
    let bodyStroke = NSBezierPath(
        roundedRect: bodyRect.insetBy(dx: 8 * scale, dy: 8 * scale),
        xRadius: 56 * scale,
        yRadius: 56 * scale
    )
    bodyStroke.lineWidth = 18 * scale
    bodyStroke.stroke()

    NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 468 * scale, y: 420 * scale, width: 88 * scale, height: 88 * scale)).fill()
    NSBezierPath(
        roundedRect: NSRect(x: 488 * scale, y: 330 * scale, width: 48 * scale, height: 120 * scale),
        xRadius: 24 * scale,
        yRadius: 24 * scale
    ).fill()

    NSColor(red: 0.17, green: 0.88, blue: 0.50, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 692 * scale, y: 664 * scale, width: 88 * scale, height: 88 * scale)).fill()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(
            domain: "IconGeneration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to render \(url.lastPathComponent)"]
        )
    }
    try data.write(to: url)
}

for size in sizes {
    try writePNG(drawIcon(size: size.pixels), to: iconsetURL.appendingPathComponent(size.fileName))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "IconGeneration",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}

print(outputURL.path)
