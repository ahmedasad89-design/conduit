#!/usr/bin/env swift
//
// Draws Conduit.icns.
//
//   swift Tools/makeicon.swift Resources
//
// Written as code rather than shipped as a binary asset so the icon can be
// tweaked and regenerated without Xcode, Sketch, or any asset pipeline —
// `iconutil` is part of the Command Line Tools. The mark is a speed gauge: a
// dark squircle, a track, a blue arc sweeping to three-quarters, and an orange
// needle, with the USB trident's three-dot motif forming the hub.

import AppKit
import Foundation

let outputRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: outputRoot).appendingPathComponent("Conduit.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let s = size
    ctx.setAllowsAntialiasing(true)

    // Full bleed, no inset.
    //
    // macOS 26 composites app icons inside its own rounded container. Drawing a
    // squircle inset from the canvas puts a second, smaller squircle inside the
    // system's one — the nested-frame look. Filling the canvas with the same
    // corner ratio the system uses makes the two coincide instead.
    let inset: CGFloat = 0
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237                     // the squircle ratio Apple uses

    // Body: a near-black graphite with a subtle vertical lift, so the icon has
    // depth without becoming a gradient exercise.
    let body = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    // Near-black, because macOS 26 draws its own dark container behind this.
    // A lighter plate reads as a second frame nested inside the system's one.
    let shades = [
        CGColor(red: 0.094, green: 0.102, blue: 0.118, alpha: 1),
        CGColor(red: 0.035, green: 0.039, blue: 0.047, alpha: 1)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: shades, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Hairline rim, the way Apple's own icons catch light at the very edge.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(max(1, s * 0.005))
    ctx.strokePath()
    ctx.restoreGState()

    // Gauge geometry: a 220-degree dial with the gap at the bottom.
    //
    // A shallow arc reads as a bowl rather than a gauge, so the sweep has to be
    // wide enough to be unmistakable at 16 points. CGContext angles run
    // counter-clockwise from east, and `clockwise: true` makes them decrease,
    // so this starts upper-left and sweeps over the top to upper-right.
    let centre = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.06)
    let radius = rect.width * 0.30
    let width = max(1.5, rect.width * 0.085)
    let startAngle = CGFloat.pi * 1.111          // 200 degrees
    let endAngle = -CGFloat.pi * 0.111           // -20 degrees
    let sweep = startAngle - endAngle            // 220 degrees

    ctx.setLineCap(.round)

    // Unfilled track.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.13))
    ctx.setLineWidth(width)
    ctx.addArc(center: centre, radius: radius,
               startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Filled portion — blue, matching the read colour used throughout the app.
    let fill: CGFloat = 0.72
    ctx.setStrokeColor(CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1))
    ctx.setLineWidth(width)
    ctx.addArc(center: centre, radius: radius,
               startAngle: startAngle, endAngle: startAngle - sweep * fill, clockwise: true)
    ctx.strokePath()

    // Needle, orange, matching the write colour. Slightly past the fill so the
    // two do not overlap into one shape.
    let needleAngle = startAngle - sweep * fill
    let tip = CGPoint(x: centre.x + cos(needleAngle) * radius * 0.80,
                      y: centre.y + sin(needleAngle) * radius * 0.80)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.58, blue: 0.16, alpha: 1))
    ctx.setLineWidth(max(1.2, rect.width * 0.048))
    ctx.move(to: centre)
    ctx.addLine(to: tip)
    ctx.strokePath()

    // Hub.
    ctx.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1))
    let hub = rect.width * 0.052
    ctx.fillEllipse(in: CGRect(x: centre.x - hub, y: centre.y - hub,
                               width: hub * 2, height: hub * 2))

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: iconset.appendingPathComponent(name))
}

// iconutil expects this exact set of names.
for base in [16, 32, 128, 256, 512] {
    write(draw(size: CGFloat(base)), pixels: base, name: "icon_\(base)x\(base).png")
    write(draw(size: CGFloat(base * 2)), pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}

print("Wrote \(iconset.path)")
