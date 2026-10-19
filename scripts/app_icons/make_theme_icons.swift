// Draws every app icon from Aurora's mark (`Shared/AuroraMark.swift`): a hairline
// horizon and the sun's arc, with one stroke rising out of it to a bead. Each
// theme's icon is its mark, in its colours, on its own ground.
//
//     swiftc -parse-as-library scripts/app_icons/make_theme_icons.swift Shared/AuroraMark.swift -o /tmp/make_icons
//     /tmp/make_icons
//
// Run from the repository root. The mark is the app's own view, rendered here,
// so the icons and the mark in the app can't drift apart. Writes the primary icon (light, dark and tinted),
// the five alternate icon sets, a ThemeIcon image set per theme for the in-app
// previews, and docs/logo.png for the README.
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

/// A theme's icon: its ground, and the mark's colours on it.
struct Look {
    let variant: AuroraMark.Variant
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
            AuroraMark(variant: look.variant, accent: Color(look.accent), bead: Color(look.bead),
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

/// The primary icon: clay on warm ivory — and, under a dark Home Screen, on
/// warm black.
let auroraLight = Look(variant: .aurora, ground: (0xF7F2EA, 0xE6DDCE), accent: 0xC8603D, bead: 0x2B2420,
                       line: (0x8C7B68, 0.55), shadow: 0.14)
let auroraDark = Look(variant: .aurora, ground: (0x1F1A17, 0x0D0B0A), accent: 0xE8794F, bead: 0xF6EEE3,
                      line: (0xB5A08A, 0.36), glow: 0.13)
/// The tinted icon: greyscale on black, which iOS tints.
let auroraTinted = Look(variant: .aurora, ground: (0x161616, 0x000000), accent: 0xD0D0D0, bead: 0xFFFFFF,
                        line: (0xFFFFFF, 0.3))

let themes: [(id: String, icon: String, look: Look)] = [
    ("tide", "AppIcon-Tide",
     Look(variant: .tide, ground: (0x10242B, 0x050E12), accent: 0x3CC8C8, bead: 0xEAF6F8,
          line: (0x8FB1BA, 0.4), glow: 0.13)),
    ("phosphor", "AppIcon-Phosphor",
     Look(variant: .phosphor, ground: (0x0F1F13, 0x040805), accent: 0x3BE477, bead: 0xD8F5DC,
          line: (0x86A98C, 0.4), glow: 0.11)),
    ("neon", "AppIcon-Neon",
     Look(variant: .neon, ground: (0x201338, 0x0A0512), accent: 0xFF3EA5, bead: 0xFFF0FA,
          line: (0xA898C4, 0.45), glow: 0.13)),
    ("bloom", "AppIcon-Bloom",
     Look(variant: .bloom, ground: (0x2C1922, 0x10090D), accent: 0xF48FB1, bead: 0xFFE4EE,
          line: (0xC29AAA, 0.4), glow: 0.12)),
    ("gilded", "AppIcon-Gilded",
     Look(variant: .gilded, ground: (0x241E15, 0x090806), accent: 0xE2B34F, bead: 0xFFF6DD,
          line: (0xD8BE84, 0.42), glow: 0.11)),
]

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

func writePreview(_ data: Data, id: String) throws {
    try write(["icon.png": data], to: "ThemeIcon-\(id).imageset", contents: contents(["""
        {
          "filename" : "icon.png",
          "idiom" : "universal"
        }
    """]))
}

@main
enum MakeIcons {
    @MainActor static func main() throws {
        // The primary icon.
        let light = icon(auroraLight), dark = icon(auroraDark)
        try write(["aurora_icon.png": light, "aurora_icon_dark.png": dark, "aurora_icon_tinted.png": icon(auroraTinted)],
                  to: "AppIcon.appiconset",
                  contents: contents([appIcon("aurora_icon.png"), appIcon("aurora_icon_dark.png", appearance: "dark"),
                                      appIcon("aurora_icon_tinted.png", appearance: "tinted")]))
        try writePreview(light, id: "aurora")
        print("wrote AppIcon")

        for theme in themes {
            let data = icon(theme.look)
            try write(["icon.png": data], to: "\(theme.icon).appiconset", contents: contents([appIcon("icon.png")]))
            try writePreview(data, id: theme.id)
            print("wrote \(theme.icon)")
        }

        // The README's logo: the primary icon at half size, its corners rounded as iOS rounds them.
        let logo = canvas(alpha: true, side: 512) { ctx in
            let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 512 * 0.2237, cornerHeight: 512 * 0.2237, transform: nil))
            ctx.clip()
            // Images draw bottom-up; undo the canvas's flip for this one.
            ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(NSBitmapImageRep(data: light)!.cgImage!, in: rect)
        }
        try logo.write(to: URL(fileURLWithPath: "docs/logo.png"))
        print("wrote docs/logo.png")
    }
}
