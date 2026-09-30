// Draws Aurora's app icon: one rising curve, rose into amber, with a glow of
// the same colours behind it and a bead at its tip, on near-black.
//
//   swiftc -O make_icon.swift -o make_icon
//   ./make_icon ../../Aurora/Assets.xcassets/AppIcon.appiconset/aurora_icon.png
//   ./make_icon ../../Aurora/Assets.xcassets/AppIcon.appiconset/aurora_icon_tinted.png --tinted
//
// Output is 1024×1024, opaque (App Store icons can't have alpha); iOS rounds
// the corners itself. `--tinted` writes the greyscale variant iOS tints.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let N = 1024
let W = CGFloat(N)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let tinted = CommandLine.arguments.contains("--tinted")
let out = CommandLine.arguments[1]

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255, g = CGFloat((hex >> 8) & 0xff) / 255, b = CGFloat(hex & 0xff) / 255
    if tinted { let l = 0.3 * r + 0.59 * g + 0.11 * b; return CGColor(srgbRed: l, green: l, blue: l, alpha: a) }
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func context() -> CGContext {
    let c = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: W); c.scaleBy(x: 1, y: -1)
    return c
}

// One rising curve, centred in the tile.
let start = CGPoint(x: 232, y: 760), end = CGPoint(x: 792, y: 280)
let curve = CGMutablePath()
curve.move(to: start)
curve.addCurve(to: end, control1: CGPoint(x: 500, y: 760), control2: CGPoint(x: 560, y: 300))
let gradient = CGGradient(colorsSpace: space,
                          colors: [rgb(0xD9566B), rgb(0xE8794F), rgb(0xF2B36B)] as CFArray,
                          locations: [0, 0.5, 1])!

/// The curve filled with its rose → clay → amber gradient, at `width`.
func stroke(_ c: CGContext, width: CGFloat) {
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(width)
    c.addPath(curve)
    c.replacePathWithStrokedPath()
    c.clip()
    c.drawLinearGradient(gradient, start: start, end: end,
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

// The aurora: the same curve, wide and blurred into light.
let glowCtx = context()
glowCtx.setFillColor(CGColor(gray: 0, alpha: 0)); glowCtx.fill(CGRect(x: 0, y: 0, width: W, height: W))
stroke(glowCtx, width: 150)
let glowIn = CIImage(cgImage: glowCtx.makeImage()!)
let glow = glowIn.clampedToExtent().applyingGaussianBlur(sigma: 70).cropped(to: glowIn.extent)
    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75)])

let ground = context()
ground.setFillColor(rgb(0x0A0A0D)); ground.fill(CGRect(x: 0, y: 0, width: W, height: W))
let ci = CIContext(options: [.workingColorSpace: space])
let base = ci.createCGImage(glow.composited(over: CIImage(cgImage: ground.makeImage()!)),
                            from: glowIn.extent, format: .RGBA8, colorSpace: space)!

let top = context()
top.saveGState(); top.translateBy(x: 0, y: W); top.scaleBy(x: 1, y: -1)
top.draw(base, in: CGRect(x: 0, y: 0, width: W, height: W))
top.restoreGState()
stroke(top, width: 56)
// The bead at the tip.
top.setFillColor(rgb(0xFFF4EA))
top.fillEllipse(in: CGRect(x: end.x - 50, y: end.y - 50, width: 100, height: 100))

let rgbCtx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
rgbCtx.draw(top.makeImage()!, in: CGRect(x: 0, y: 0, width: W, height: W))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, rgbCtx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
