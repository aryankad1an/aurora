// Draws the app icon from Aurora's mark (`Shared/AuroraMark.swift`): a hairline
// horizon with a striped seventies sun on it, and one stroke rising out of it
// to a bead.
//
//     swiftc -parse-as-library scripts/app_icons/make_icons.swift Shared/AuroraMark.swift -o /tmp/make_icons
//     /tmp/make_icons
//
// Run from the repository root. The mark is the app's own view, rendered here,
// so the icon and the mark in the app can't drift apart. Writes the icon (light,
// dark and tinted) and docs/logo.png for the README.
//
// Output is 1024×1024 and opaque (App Store icons can't have alpha); iOS rounds
// the corners itself.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

let side: CGFloat = 1024
let assets = URL(fileURLWithPath: "Aurora/Assets.xcassets")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A context with a top-left origin, like UIKit.
func canvas(alpha: Bool = false, side: CGFloat = side, _ draw: (CGContext) -> Void) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: info.rawValue)!
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Icons

extension Color {
    init(_ hex: UInt32, _ alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// An icon's ground, and the mark's colours on it.
struct Look {
    /// The ground: lifted near the top, deeper at the edges.
    let ground: (center: UInt32, edge: UInt32)
    let accent: UInt32
    let bead: UInt32
    let line: (UInt32, Double)
    /// A soft light of the accent behind the mark; zero on the light icon.
    var glow: Double = 0
    /// The shadow under the mark, for depth on a light ground.
    var shadow: Double = 0
}

struct IconView: View {
    let look: Look

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(look.ground.center), Color(look.ground.edge)],
                           center: UnitPoint(x: 0.5, y: 0.36), startRadius: 0, endRadius: side * 0.82)
            RadialGradient(colors: [Color(look.accent, look.glow), Color(look.accent, 0)],
                           center: UnitPoint(x: 0.56, y: 0.5), startRadius: 0, endRadius: side * 0.48)
            AuroraMark(accent: Color(look.accent), bead: Color(look.bead),
                       line: Color(look.line.0, look.line.1))
                .padding(side * 0.11)
                .shadow(color: Color(0x3A2418, look.shadow), radius: side * 0.018, y: side * 0.01)
        }
        .frame(width: side, height: side)
    }
}

/// The icon, opaque.
@MainActor func icon(_ look: Look) -> Data {
    let renderer = ImageRenderer(content: IconView(look: look))
    renderer.scale = 1
    let image = renderer.cgImage!
    return canvas { ctx in
        ctx.translateBy(x: 0, y: side); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
}

// MARK: - Looks

/// Burnt orange on cream — and, under a dark Home Screen, on warm black.
let light = Look(ground: (0xF6EEDF, 0xE6D8C0), accent: 0xD9552B, bead: 0x2A211A,
                 line: (0x8C7B68, 0.55), shadow: 0.14)
let dark = Look(ground: (0x241D17, 0x0E0B09), accent: 0xF26A3D, bead: 0xF4EADB,
                line: (0xB3A794, 0.4), glow: 0.14)
/// The tinted icon: greyscale on black, which iOS tints.
let tinted = Look(ground: (0x161616, 0x000000), accent: 0xD0D0D0, bead: 0xFFFFFF,
                  line: (0xFFFFFF, 0.3))

// MARK: - Writing

func contents(_ images: [String]) -> String {
    """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

func appIcon(_ file: String, appearance: String? = nil) -> String {
    let appearances = appearance.map {
        """
              "appearances" : [
                {
                  "appearance" : "luminosity",
                  "value" : "\($0)"
                }
              ],

        """
    } ?? ""
    return """
        {
    \(appearances)      "filename" : "\(file)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
    """
}

func write(_ files: [String: Data], to set: String, contents json: String) throws {
    let dir = assets.appendingPathComponent(set)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
    try json.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

@main
enum MakeIcons {
    @MainActor static func main() throws {
        let lightIcon = icon(light)
        try write(["aurora_icon.png": lightIcon, "aurora_icon_dark.png": icon(dark),
                   "aurora_icon_tinted.png": icon(tinted)],
                  to: "AppIcon.appiconset",
                  contents: contents([appIcon("aurora_icon.png"), appIcon("aurora_icon_dark.png", appearance: "dark"),
                                      appIcon("aurora_icon_tinted.png", appearance: "tinted")]))
        print("wrote AppIcon")

        // The README's logo: the icon at half size, its corners rounded as iOS rounds them.
        let logo = canvas(alpha: true, side: 512) { ctx in
            let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 512 * 0.2237, cornerHeight: 512 * 0.2237, transform: nil))
            ctx.clip()
            // Images draw bottom-up; undo the canvas's flip for this one.
            ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(NSBitmapImageRep(data: lightIcon)!.cgImage!, in: rect)
        }
        try logo.write(to: URL(fileURLWithPath: "docs/logo.png"))
        print("wrote docs/logo.png")
    }
}
