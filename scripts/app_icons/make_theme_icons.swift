// Draws the alternate app icons, one per theme, in the style of the primary
// icon (a glowing chart on a dark ground), and writes them into the asset
// catalog both as alternate app icon sets and as image sets the app can show.
//
//     swift scripts/app_icons/make_theme_icons.swift
//
// Run from the repository root. The Aurora icon is the primary icon and is
// only copied (as ThemeIcon-aurora) for the in-app previews.

import AppKit
import CoreGraphics
import Foundation

let side: CGFloat = 1024
let assets = URL(fileURLWithPath: "Aurora/Assets.xcassets")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A context with a top-left origin, like UIKit.
func canvas(_ draw: (CGContext) -> Void) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func ground(_ ctx: CGContext, _ base: UInt32, glow: UInt32, at center: CGPoint) {
    ctx.setFillColor(rgb(base))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(glow, 0.22), rgb(glow, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 620, options: [])
}

/// A stroke filled with a gradient along `from`→`to`, haloed by a soft glow.
func glowStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, colors: [UInt32], from: CGPoint, to: CGPoint,
                glow: CGFloat = 1) {
    let mid = colors[colors.count / 2]
    for i in stride(from: 14, through: 1, by: -1) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width + CGFloat(i) * 14 * glow)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgb(mid, 0.028))
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: colors.map { rgb($0) } as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func dot(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, glow: UInt32, fill: UInt32 = 0xFBF3EA) {
    let halo = CGGradient(colorsSpace: nil, colors: [rgb(glow, 0.55), rgb(glow, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius * 3.4, options: [])
    ctx.setFillColor(rgb(fill))
    ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
}

func curve(_ points: Int, _ f: (CGFloat) -> CGPoint) -> CGPath {
    let path = CGMutablePath()
    for i in 0...points {
        let p = f(CGFloat(i) / CGFloat(points))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    return path
}

// MARK: - Designs

func tide() -> Data {
    canvas { ctx in
        ground(ctx, 0x061014, glow: 0x3CC8C8, at: CGPoint(x: 560, y: 520))
        for band in (0..<3).reversed() {
            let b = CGFloat(band)
            let base = 560 + b * 120
            let wave = curve(120) { t in
                CGPoint(x: t * side, y: base - 70 * sin(t * .pi * (1.8 + 0.3 * b) + b * 0.9) * (1 - 0.25 * b))
            }
            let fill = CGMutablePath()
            fill.addPath(wave)
            fill.addLine(to: CGPoint(x: side, y: side)); fill.addLine(to: CGPoint(x: 0, y: side)); fill.closeSubpath()
            ctx.saveGState()
            ctx.addPath(fill); ctx.clip()
            let g = CGGradient(colorsSpace: nil, colors: [rgb(0x3CC8C8, 0.34 - 0.08 * b), rgb(0x0B3A5A, 0.05)] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base - 80), end: CGPoint(x: 0, y: side), options: [])
            ctx.restoreGState()
        }
        let crest = curve(140) { t in
            let x = 180 + t * 640
            return CGPoint(x: x, y: 700 - 400 * t + 70 * sin(t * .pi * 2.4))
        }
        glowStroke(ctx, crest, width: 56, colors: [0x2A8FB8, 0x3CC8C8, 0x9EF0DD],
                   from: CGPoint(x: 180, y: 760), to: CGPoint(x: 820, y: 280))
        dot(ctx, at: CGPoint(x: 820, y: 300 + 70 * sin(.pi * 2.4)), radius: 50, glow: 0x9EF0DD)
    }
}

func phosphor() -> Data {
    canvas { ctx in
        ground(ctx, 0x050A06, glow: 0x3BE477, at: CGPoint(x: 520, y: 560))
        ctx.setStrokeColor(rgb(0x173020, 0.9)); ctx.setLineWidth(3)
        for i in 1..<6 {
            let y = CGFloat(i) * side / 6
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: side, y: y))
        }
        ctx.strokePath()
        let closes: [CGFloat] = [760, 700, 730, 600, 540, 420, 340]
        var previous: CGFloat = 800
        for (i, close) in closes.enumerated() {
            let x = 170 + CGFloat(i) * 112
            let up = close < previous
            let top = min(previous, close), bottom = max(previous, close)
            ctx.setStrokeColor(rgb(up ? 0x3BE477 : 0xFF6B5E, 0.85)); ctx.setLineWidth(8)
            ctx.move(to: CGPoint(x: x, y: top - 50)); ctx.addLine(to: CGPoint(x: x, y: bottom + 50)); ctx.strokePath()
            let body = CGRect(x: x - 30, y: top, width: 60, height: max(bottom - top, 16))
            if up {
                ctx.setFillColor(rgb(0x3BE477, 0.9)); ctx.fill(body)
            } else {
                ctx.setStrokeColor(rgb(0xFF6B5E, 0.85)); ctx.setLineWidth(8); ctx.stroke(body)
            }
            previous = close
        }
        let average = curve(100) { t in CGPoint(x: 150 + t * 700, y: 800 - 470 * t + 40 * sin(t * .pi * 2)) }
        glowStroke(ctx, average, width: 30, colors: [0x2FB866, 0x5EE0D6], from: CGPoint(x: 150, y: 800),
                   to: CGPoint(x: 850, y: 330), glow: 0.8)
        dot(ctx, at: CGPoint(x: 850, y: 330), radius: 44, glow: 0x5EE0D6, fill: 0xE9FFEE)
    }
}

func neon() -> Data {
    canvas { ctx in
        ground(ctx, 0x0B0614, glow: 0xFF3EA5, at: CGPoint(x: 512, y: 600))
        let horizon: CGFloat = 620
        // The sun.
        ctx.saveGState()
        ctx.addRect(CGRect(x: 0, y: 0, width: side, height: horizon)); ctx.clip()
        ctx.addEllipse(in: CGRect(x: 512 - 250, y: horizon - 330, width: 500, height: 500)); ctx.clip()
        let sun = CGGradient(colorsSpace: nil, colors: [rgb(0xFFB547), rgb(0xFF3EA5)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sun, start: CGPoint(x: 0, y: horizon - 330), end: CGPoint(x: 0, y: horizon), options: [])
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x0B0614))
        for i in 0..<5 {
            let y = horizon - 30 - CGFloat(i) * 46
            ctx.fill(CGRect(x: 0, y: y, width: side, height: 10 + CGFloat(i) * 2))
        }
        // The floor.
        ctx.setStrokeColor(rgb(0xFF3EA5, 0.75)); ctx.setLineWidth(5)
        for i in 1...7 {
            let d = CGFloat(i) / 7
            let y = horizon + (side - horizon) * d * d
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: side, y: y))
        }
        for k in -6...6 {
            ctx.move(to: CGPoint(x: 512, y: horizon)); ctx.addLine(to: CGPoint(x: 512 + CGFloat(k) * 220, y: side))
        }
        ctx.strokePath()
        // The signal.
        let line = CGMutablePath()
        let points: [CGPoint] = [CGPoint(x: 150, y: 560), CGPoint(x: 330, y: 440), CGPoint(x: 450, y: 520),
                                 CGPoint(x: 620, y: 300), CGPoint(x: 720, y: 380), CGPoint(x: 860, y: 200)]
        line.addLines(between: points)
        glowStroke(ctx, line, width: 34, colors: [0x3EE6F0, 0x9C8CFF, 0xFF3EA5], from: points[0], to: points[5])
        dot(ctx, at: points[5], radius: 42, glow: 0xFF3EA5, fill: 0xFFF0FA)
    }
}

func bloom() -> Data {
    canvas { ctx in
        ground(ctx, 0x120A0E, glow: 0xF48FB1, at: CGPoint(x: 500, y: 540))
        let stem = curve(120) { t in
            let x = 230 + t * 560
            return CGPoint(x: x, y: 770 - 490 * (t * t * (3 - 2 * t)))
        }
        glowStroke(ctx, stem, width: 54, colors: [0xC2557E, 0xF48FB1, 0xFFD3E2],
                   from: CGPoint(x: 230, y: 770), to: CGPoint(x: 790, y: 280))
        // Petals drifting off the curve.
        let petals: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (300, 560, 30, 0.6), (420, 430, 22, 1.4), (560, 620, 26, 2.2), (640, 330, 18, 0.2),
            (720, 520, 24, 1.1), (360, 330, 16, 2.8), (850, 420, 20, 0.9), (500, 250, 14, 1.9)]
        for (x, y, r, angle) in petals {
            ctx.saveGState()
            ctx.translateBy(x: x, y: y); ctx.rotate(by: angle)
            ctx.setFillColor(rgb(0xF48FB1, 0.55))
            ctx.fillEllipse(in: CGRect(x: -r * 1.5, y: -r, width: r * 3, height: r * 2))
            ctx.setFillColor(rgb(0xFFE4EE, 0.5))
            ctx.fillEllipse(in: CGRect(x: -r * 0.6, y: -r * 0.4, width: r * 1.2, height: r * 0.8))
            ctx.restoreGState()
        }
        dot(ctx, at: CGPoint(x: 790, y: 280), radius: 50, glow: 0xFFB3CD)
    }
}

func gilded() -> Data {
    canvas { ctx in
        let center = CGPoint(x: 512, y: 512)
        ground(ctx, 0x0A0907, glow: 0xE2B34F, at: center)
        ctx.setStrokeColor(rgb(0xE2B34F, 0.32)); ctx.setLineWidth(5)
        for k in 1...4 {
            let r = CGFloat(k) * 95
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            ctx.move(to: center); ctx.addLine(to: CGPoint(x: center.x + 380 * cos(a), y: center.y + 380 * sin(a)))
        }
        ctx.strokePath()
        // The sweep.
        let sweep: CGFloat = -.pi / 4
        ctx.saveGState()
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: 380, startAngle: sweep - 1.0, endAngle: sweep, clockwise: false)
        wedge.closeSubpath()
        ctx.addPath(wedge); ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [rgb(0xE2B34F, 0), rgb(0xE2B34F, 0.45)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: center.x + 380 * cos(sweep - 1), y: center.y + 380 * sin(sweep - 1)),
                               end: CGPoint(x: center.x + 380 * cos(sweep), y: center.y + 380 * sin(sweep)), options: [])
        ctx.restoreGState()
        let arm = CGMutablePath()
        arm.move(to: center); arm.addLine(to: CGPoint(x: center.x + 380 * cos(sweep), y: center.y + 380 * sin(sweep)))
        glowStroke(ctx, arm, width: 26, colors: [0xB8862F, 0xF3D58A], from: center,
                   to: CGPoint(x: center.x + 380 * cos(sweep), y: center.y + 380 * sin(sweep)), glow: 0.7)
        for (r, a) in [(240.0, -0.9), (150.0, 2.2), (310.0, 1.1), (200.0, 3.6)] as [(CGFloat, CGFloat)] {
            dot(ctx, at: CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)), radius: 16, glow: 0xE2B34F, fill: 0xF3D58A)
        }
        dot(ctx, at: CGPoint(x: center.x + 380 * cos(sweep), y: center.y + 380 * sin(sweep)), radius: 46, glow: 0xF3D58A,
            fill: 0xFFF6DD)
    }
}

// MARK: - Writing

func write(_ data: Data, iconSet name: String) throws {
    let dir = assets.appendingPathComponent("\(name).appiconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: dir.appendingPathComponent("icon.png"))
    let contents = """
    {
      "images" : [
        {
          "filename" : "icon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

func write(_ data: Data, imageSet name: String) throws {
    let dir = assets.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: dir.appendingPathComponent("icon.png"))
    let contents = """
    {
      "images" : [
        {
          "filename" : "icon.png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

let designs: [(id: String, icon: String, draw: () -> Data)] = [
    ("tide", "AppIcon-Tide", tide), ("phosphor", "AppIcon-Phosphor", phosphor), ("neon", "AppIcon-Neon", neon),
    ("bloom", "AppIcon-Bloom", bloom), ("gilded", "AppIcon-Gilded", gilded),
]
for design in designs {
    let data = design.draw()
    try write(data, iconSet: design.icon)
    try write(data, imageSet: "ThemeIcon-\(design.id)")
    print("wrote \(design.icon)")
}
let primary = try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/aurora_icon.png"))
try write(primary, imageSet: "ThemeIcon-aurora")
print("wrote ThemeIcon-aurora")
