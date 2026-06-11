#!/usr/bin/env swift
// Generates Assets/AppIcon.icns — the SonicRouter app icon.
// Draws a macOS-style squircle with an indigo gradient and three mixer
// faders, renders every iconset size, and packs them with `iconutil`.
//
// Usage: swift Scripts/make-icon.swift [output-dir]   (default: Assets)

import AppKit

let arguments = CommandLine.arguments
let scriptURL = URL(fileURLWithPath: arguments[0])
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDir = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : rootDir.appendingPathComponent("Assets")

// MARK: - Drawing

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("No se pudo crear el bitmap de \(pixels)px")
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Apple icon grid: the squircle covers ~82% of the canvas.
    let margin = size * 0.09
    let plate = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = plate.width * 0.2237
    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Soft drop shadow behind the plate.
    if pixels >= 64 {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.shadowBlurRadius = size * 0.028
        shadow.set()
        NSColor(calibratedRed: 0.25, green: 0.28, blue: 0.86, alpha: 1).setFill()
        squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Indigo → violet gradient, lighter at the top.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.50, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.99, alpha: 1),
        NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.78, alpha: 1)
    ])
    gradient?.draw(in: squircle, angle: -90)

    // Subtle top highlight for depth.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let highlight = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.18),
        ending: NSColor.white.withAlphaComponent(0)
    )
    highlight?.draw(
        in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
        angle: -90
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    // Three mixer faders: dim tracks with bright knobs at different levels.
    let trackXs: [CGFloat] = [0.335, 0.5, 0.665]
    let knobLevels: [CGFloat] = [0.68, 0.34, 0.55] // 0 = bottom of track, 1 = top
    let trackTop = plate.minY + plate.height * 0.76
    let trackBottom = plate.minY + plate.height * 0.24
    let trackWidth = size * 0.052
    let knobRadius = size * 0.062

    for (index, relX) in trackXs.enumerated() {
        let x = plate.minX + plate.width * relX
        let track = NSRect(
            x: x - trackWidth / 2,
            y: trackBottom,
            width: trackWidth,
            height: trackTop - trackBottom
        )
        NSColor.white.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

        let knobY = trackBottom + (trackTop - trackBottom) * knobLevels[index]

        // Filled portion below the knob, like a level meter.
        let filled = NSRect(
            x: x - trackWidth / 2,
            y: trackBottom,
            width: trackWidth,
            height: max(trackWidth, knobY - trackBottom)
        )
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

        if pixels >= 64 {
            NSGraphicsContext.current?.saveGraphicsState()
            let knobShadow = NSShadow()
            knobShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            knobShadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
            knobShadow.shadowBlurRadius = size * 0.012
            knobShadow.set()
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: x - knobRadius,
            y: knobY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )).fill()
        if pixels >= 64 {
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    return rep
}

// MARK: - Iconset + icns

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let fileManager = FileManager.default
let iconsetURL = outputDir.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for entry in entries {
    let rep = drawIcon(pixels: entry.pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("No se pudo generar el PNG de \(entry.pixels)px")
    }
    try png.write(to: iconsetURL.appendingPathComponent("\(entry.name).png"))
}

let icnsURL = outputDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil falló con código \(iconutil.terminationStatus)")
}

try? fileManager.removeItem(at: iconsetURL)
print(icnsURL.path)
