#!/usr/bin/env swift
// Renders the VoxelScanner app icon to a 1024×1024 PNG.
//
// Design: aperture-science-style iris blades around an isometric voxel cube,
// drawn in the app's mocha/cream palette. Run with:
//
//   swift ios/VoxelScanner/scripts/generate_icon.swift <output-path>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outPath = args.count > 1
    ? args[1]
    : "ios/VoxelScanner/VoxelScanner/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("Failed to allocate context\n".data(using: .utf8)!)
    exit(1)
}

// MARK: Palette (matches Theme in ContentView.swift)
func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
let bgTop    = c(0x2C, 0x1F, 0x1A)
let bgBottom = c(0x0E, 0x08, 0x06)
let ivory    = c(0xF5, 0xEF, 0xE6)
let muted    = c(0xC8, 0xB5, 0xA5)
let salmon   = c(0xEA, 0xAC, 0xB2)
let orange   = c(0xDD, 0x95, 0x6B)
let sage     = c(0xA2, 0xC0, 0xA7)

let center = CGPoint(x: size / 2, y: size / 2)
let fullRect = CGRect(origin: .zero, size: CGSize(width: size, height: size))

// MARK: Background radial gradient
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [bgTop, bgBottom] as CFArray,
                        locations: [0, 1])!
ctx.drawRadialGradient(
    bgGrad,
    startCenter: center, startRadius: 0,
    endCenter: center, endRadius: size * 0.75,
    options: []
)

// MARK: Aperture iris
// Two concentric guide rings, then 6 tapered iris blades.
let outerR: CGFloat = size * 0.42
let innerR: CGFloat = size * 0.22
let ringWidth: CGFloat = size * 0.018

// Outer thin ring
ctx.setStrokeColor(ivory.copy(alpha: 0.9)!)
ctx.setLineWidth(ringWidth * 1.2)
ctx.strokeEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR,
                             width: outerR * 2, height: outerR * 2))

// Inner thin ring
ctx.setStrokeColor(ivory.copy(alpha: 0.35)!)
ctx.setLineWidth(ringWidth * 0.6)
ctx.strokeEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR,
                             width: innerR * 2, height: innerR * 2))

// Iris blades: 6 asymmetric petals. Each blade's inner arc is rotated
// "back" relative to its outer arc so the blade appears to curl inward —
// the classic aperture look.
let bladeCount = 6
let bladeSpan: CGFloat = (.pi * 2) / CGFloat(bladeCount)
let innerOffset: CGFloat = bladeSpan * 0.55   // curl amount
let gap: CGFloat = bladeSpan * 0.08           // gap between adjacent blades

for i in 0..<bladeCount {
    let s = CGFloat(i) * bladeSpan + gap / 2
    let e = s + bladeSpan - gap

    let path = CGMutablePath()
    // Outer arc, counter-clockwise from s to e.
    path.addArc(
        center: center, radius: outerR * 0.95,
        startAngle: s, endAngle: e,
        clockwise: false
    )
    // Jump inward and back along the inner ring, rotated by -innerOffset
    // so the blade curls. CG auto-draws a line between the two arcs.
    path.addArc(
        center: center, radius: innerR * 1.02,
        startAngle: e - innerOffset, endAngle: s - innerOffset,
        clockwise: true
    )
    path.closeSubpath()

    ctx.addPath(path)
    ctx.setFillColor(ivory.copy(alpha: 0.93)!)
    ctx.fillPath()
}

// MARK: Center punch — dark hole inside the iris
let holeR: CGFloat = size * 0.11
ctx.setFillColor(bgBottom)
ctx.fillEllipse(in: CGRect(x: center.x - holeR, y: center.y - holeR,
                           width: holeR * 2, height: holeR * 2))

// Thin rim around the hole
ctx.setStrokeColor(ivory.copy(alpha: 0.4)!)
ctx.setLineWidth(ringWidth * 0.4)
ctx.strokeEllipse(in: CGRect(x: center.x - holeR, y: center.y - holeR,
                             width: holeR * 2, height: holeR * 2))

// MARK: Isometric voxel cube in the hole
// Three parallelograms forming a cube, each face different theme colour.
let s: CGFloat = size * 0.10             // edge length (slightly bigger)
let root = CGPoint(x: center.x, y: center.y + s * 0.55)
let dx = s * cos(.pi / 6)                // horizontal component of iso edge
let dy = s * sin(.pi / 6)                // vertical component of iso edge

// Vertices of the cube in isometric projection.
let bottomFront = CGPoint(x: root.x,          y: root.y)
let rightFront  = CGPoint(x: root.x + dx,     y: root.y - dy)
let leftFront   = CGPoint(x: root.x - dx,     y: root.y - dy)
let topFront    = CGPoint(x: root.x,          y: root.y - dy * 2)
let rightTop    = CGPoint(x: rightFront.x,    y: rightFront.y - s)
let leftTop     = CGPoint(x: leftFront.x,     y: leftFront.y - s)
let topTop      = CGPoint(x: topFront.x,      y: topFront.y - s)

func drawFace(_ pts: [CGPoint], fill: CGColor) {
    let p = CGMutablePath()
    p.move(to: pts[0])
    for pt in pts.dropFirst() { p.addLine(to: pt) }
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.addPath(p)
    ctx.setStrokeColor(ivory.copy(alpha: 0.5)!)
    ctx.setLineWidth(size * 0.004)
    ctx.strokePath()
}

// Top face (brightest).
drawFace([topFront, rightTop, topTop, leftTop], fill: ivory)
// Left face (salmon).
drawFace([leftFront, topFront, topTop, leftTop], fill: salmon)
// Right face (orange — darker side).
drawFace([rightFront, topFront, topTop, rightTop], fill: orange)

// MARK: Tiny voxel dots scattered on the dark background outside the iris
// Gives a subtle "point cloud" backdrop.
srand48(42)
for _ in 0..<140 {
    let angle = CGFloat(drand48()) * .pi * 2
    // Confine between outer ring and canvas edge.
    let r = outerR * (1.06 + CGFloat(drand48()) * 0.45)
    let x = center.x + cos(angle) * r
    let y = center.y + sin(angle) * r
    if x < 0 || x > size || y < 0 || y > size { continue }
    let dotSize = size * (0.004 + CGFloat(drand48()) * 0.006)
    let alpha = CGFloat(0.12 + drand48() * 0.28)
    ctx.setFillColor(ivory.copy(alpha: alpha)!)
    ctx.fillEllipse(in: CGRect(x: x - dotSize, y: y - dotSize,
                               width: dotSize * 2, height: dotSize * 2))
}

// A single accent cluster in salmon/sage for a pop.
for _ in 0..<18 {
    let angle = CGFloat.pi * 0.32 + CGFloat(drand48() - 0.5) * 0.35
    let r = outerR * (1.08 + CGFloat(drand48()) * 0.18)
    let x = center.x + cos(angle) * r
    let y = center.y + sin(angle) * r
    let dotSize = size * 0.006
    ctx.setFillColor((drand48() > 0.5 ? salmon : sage).copy(alpha: 0.65)!)
    ctx.fillEllipse(in: CGRect(x: x - dotSize, y: y - dotSize,
                               width: dotSize * 2, height: dotSize * 2))
}

// MARK: Write PNG
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to render image\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    FileHandle.standardError.write("Failed to create PNG destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("Failed to finalise PNG\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(outPath)")
