// Generates Support/dmg-background@2x.png — the dmg window background.
// One-off tool, committed so the asset is regenerable:
//   swift scripts/gen-dmg-background.swift
// Coordinates assume a 600x400 pt dmg window (create-dmg config lives in
// scripts/make-dmg.sh): app icon at (150,200), Applications link at
// (450,200), so the arrow sits between them at window center.
import AppKit

let pixelWidth: Int = 1200
let pixelHeight: Int = 800

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0) else { fatalError("failed to create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// Paper tone, matching the app's paper UI theme.
NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
NSRect(origin: .zero, size: NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))).fill()

let title = "fabulous" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
]
let tSize = title.size(withAttributes: titleAttrs)
title.draw(
    at: NSPoint(x: (CGFloat(pixelWidth) - tSize.width) / 2, y: 620),
    withAttributes: titleAttrs)

let arrow = "→" as NSString
let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 96, weight: .light),
    .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
]
let aSize = arrow.size(withAttributes: arrowAttrs)
arrow.draw(
    at: NSPoint(x: (CGFloat(pixelWidth) - aSize.width) / 2, y: 400 - aSize.height / 2),
    withAttributes: arrowAttrs)

NSGraphicsContext.restoreGraphicsState()

// Finder renders dmg backgrounds at the image's metadata (point) size, not
// its pixel size. Without this, a 1200x800 px @72 DPI image would be
// stretched to 1200x800 pt in the 600x400 pt dmg window. Setting the point
// size to match the window (600x400) encodes 144 DPI into the PNG so it
// renders at the intended @2x scale.
bitmap.size = NSSize(width: 600, height: 400)

guard let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("png encode failed") }
try png.write(to: URL(fileURLWithPath: "Support/dmg-background@2x.png"))
print("wrote Support/dmg-background@2x.png")
