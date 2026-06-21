#!/usr/bin/env swift
import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Atoll.icns")
let workURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Atoll.iconset-\(UUID().uuidString)")
let iconsetURL = workURL.appendingPathExtension("iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workURL) }

func point(_ x: CGFloat, _ y: CGFloat, in rect: NSRect) -> NSPoint {
    NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
}

func drawGlyph(in rect: NSRect, color: NSColor) {
    let path = NSBezierPath()

    path.move(to: point(0.50, 0.96, in: rect))
    path.curve(to: point(0.91, 0.67, in: rect), controlPoint1: point(0.70, 0.96, in: rect), controlPoint2: point(0.86, 0.84, in: rect))
    path.curve(to: point(0.83, 0.27, in: rect), controlPoint1: point(0.95, 0.51, in: rect), controlPoint2: point(0.93, 0.36, in: rect))
    path.curve(to: point(0.50, 0.08, in: rect), controlPoint1: point(0.74, 0.16, in: rect), controlPoint2: point(0.62, 0.10, in: rect))
    path.curve(to: point(0.13, 0.28, in: rect), controlPoint1: point(0.35, 0.05, in: rect), controlPoint2: point(0.20, 0.13, in: rect))
    path.curve(to: point(0.09, 0.67, in: rect), controlPoint1: point(0.05, 0.42, in: rect), controlPoint2: point(0.05, 0.56, in: rect))
    path.curve(to: point(0.50, 0.96, in: rect), controlPoint1: point(0.14, 0.84, in: rect), controlPoint2: point(0.30, 0.96, in: rect))
    path.close()

    path.move(to: point(0.50, 0.72, in: rect))
    path.curve(to: point(0.67, 0.58, in: rect), controlPoint1: point(0.58, 0.72, in: rect), controlPoint2: point(0.65, 0.66, in: rect))
    path.curve(to: point(0.61, 0.39, in: rect), controlPoint1: point(0.69, 0.50, in: rect), controlPoint2: point(0.66, 0.43, in: rect))
    path.curve(to: point(0.48, 0.34, in: rect), controlPoint1: point(0.57, 0.35, in: rect), controlPoint2: point(0.52, 0.34, in: rect))
    path.curve(to: point(0.32, 0.47, in: rect), controlPoint1: point(0.41, 0.34, in: rect), controlPoint2: point(0.35, 0.38, in: rect))
    path.curve(to: point(0.37, 0.65, in: rect), controlPoint1: point(0.30, 0.54, in: rect), controlPoint2: point(0.32, 0.61, in: rect))
    path.curve(to: point(0.50, 0.72, in: rect), controlPoint1: point(0.40, 0.69, in: rect), controlPoint2: point(0.45, 0.72, in: rect))
    path.close()

    path.windingRule = .evenOdd
    color.setFill()
    path.fill()
}

func writePNG(points: Int, scale: Int, name: String) throws {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22).fill()
    drawGlyph(in: rect.insetBy(dx: CGFloat(pixels) * 0.18, dy: CGFloat(pixels) * 0.24), color: .white)
    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    try png.write(to: iconsetURL.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(points: points, scale: 1, name: "icon_\(points)x\(points).png")
    try writePNG(points: points, scale: 2, name: "icon_\(points)x\(points)@2x.png")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw CocoaError(.fileWriteUnknown)
}
