#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

let captureSize = CGSize(width: 440, height: 80)
let arguments = CommandLine.arguments

guard arguments.count == 3 else {
    fputs("usage: capture-notch.swift RAW.png ANNOTATED.png\n", stderr)
    exit(64)
}

let rawURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let annotatedURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
guard rawURL != annotatedURL else {
    fputs("raw and annotated outputs must be different files\n", stderr)
    exit(64)
}

guard let screen = NSScreen.screens.first(where: {
    $0.safeAreaInsets.top > 0
        && $0.auxiliaryTopLeftArea != nil
        && $0.auxiliaryTopRightArea != nil
}), let left = screen.auxiliaryTopLeftArea,
   let right = screen.auxiliaryTopRightArea,
   right.minX > left.maxX,
   let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
    fputs("no capturable notched display is available\n", stderr)
    exit(69)
}

let shareableContent: SCShareableContent
do {
    shareableContent = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )
} catch {
    fputs("could not read shareable displays: \(error.localizedDescription)\n", stderr)
    exit(77)
}

guard let display = shareableContent.displays.first(where: {
    $0.displayID == displayNumber.uint32Value
}) else {
    fputs("the notched display is not available to ScreenCaptureKit\n", stderr)
    exit(69)
}

let configuration = SCStreamConfiguration()
configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
configuration.captureResolution = .best
configuration.showsCursor = false

let displayImage: CGImage
do {
    displayImage = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: display, excludingWindows: []),
        configuration: configuration
    )
} catch {
    fputs("could not capture the notched display: \(error.localizedDescription)\n", stderr)
    exit(77)
}

let scaleX = CGFloat(displayImage.width) / screen.frame.width
let scaleY = CGFloat(displayImage.height) / screen.frame.height
guard abs(scaleX - scaleY) < 0.01 else {
    fputs("display has inconsistent backing scale\n", stderr)
    exit(70)
}

let physicalWidth = right.minX - left.maxX
let physicalHeight = screen.safeAreaInsets.top
let physicalCenterX = (left.maxX + right.minX) / 2
guard let application = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleURL?.standardizedFileURL.path == "/Applications/Topside.app"
}), let windowInfo = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[CFString: Any]] else {
    fputs("the installed Topside process is not running\n", stderr)
    exit(69)
}

let windowBoundsCandidates = windowInfo
    .filter { ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value == application.processIdentifier }
    .compactMap { info -> CGRect? in
        guard let dictionary = info[kCGWindowBounds] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }
guard let windowBounds = windowBoundsCandidates.first(where: {
    abs($0.height - 340) < 0.5 && (430...450).contains($0.width)
}) else {
    fputs("the installed Topside island window is not visible\n", stderr)
    exit(69)
}

let centerDeltaPixels = Int(((windowBounds.midX - physicalCenterX) * scaleX).rounded())
let cropOriginX = physicalCenterX - screen.frame.minX - captureSize.width / 2
let cropRect = CGRect(
    x: cropOriginX * scaleX,
    y: 0,
    width: captureSize.width * scaleX,
    height: captureSize.height * scaleY
)

guard CGRect(x: 0, y: 0, width: displayImage.width, height: displayImage.height).contains(cropRect),
      let crop = displayImage.cropping(to: cropRect) else {
    fputs("could not crop the notch-centered display band\n", stderr)
    exit(70)
}

func pngData(for image: CGImage, annotate: Bool) -> Data? {
    let width = image.width
    let height = image.height
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSImage(cgImage: image, size: NSSize(width: width, height: height)).draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: .zero,
        operation: .copy,
        fraction: 1
    )

    if annotate {
        let physicalRect = NSRect(
            x: (captureSize.width / 2 - physicalWidth / 2) * scaleX,
            y: CGFloat(height) - physicalHeight * scaleY,
            width: physicalWidth * scaleX,
            height: physicalHeight * scaleY
        )
        NSColor.black.setFill()
        physicalRect.fill()

        let lineWidth = max(1, scaleX)
        let outline = NSBezierPath(rect: physicalRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        outline.lineWidth = lineWidth
        NSColor.systemPink.setStroke()
        outline.stroke()

        let delta = centerDeltaPixels >= 0 ? "+\(centerDeltaPixels)" : "\(centerDeltaPixels)"
        let label = "LIVE BOUNDS \(Int(physicalWidth))×\(Int(physicalHeight)) PT · WINDOW Δ \(delta) PX" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9 * scaleX, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let labelSize = label.size(withAttributes: attributes)
        let padding = 6 * scaleX
        let badge = NSRect(
            x: 8 * scaleX,
            y: 8 * scaleY,
            width: labelSize.width + padding * 2,
            height: labelSize.height + padding
        )
        let badgePath = NSBezierPath(
            roundedRect: badge,
            xRadius: 4 * scaleX,
            yRadius: 4 * scaleY
        )
        NSColor.black.withAlphaComponent(0.82).setFill()
        badgePath.fill()
        badgePath.lineWidth = lineWidth
        NSColor.systemPink.setStroke()
        badgePath.stroke()
        label.draw(
            at: NSPoint(x: badge.minX + padding, y: badge.minY + padding / 2),
            withAttributes: attributes
        )
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

guard let rawPNG = pngData(for: crop, annotate: false),
      let annotatedPNG = pngData(for: crop, annotate: true) else {
    fputs("could not encode notch captures\n", stderr)
    exit(70)
}

do {
    try rawPNG.write(to: rawURL, options: .atomic)
    try annotatedPNG.write(to: annotatedURL, options: .atomic)
    print(
        "Captured \(Int(captureSize.width))x\(Int(captureSize.height)) points at \(scaleX)x; "
            + "physical notch x=\(left.maxX)...\(right.minX), center=\(physicalCenterX); "
            + "Topside window center delta=\(centerDeltaPixels) px."
    )
} catch {
    fputs("could not write captures: \(error.localizedDescription)\n", stderr)
    exit(73)
}
