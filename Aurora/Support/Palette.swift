import SwiftUI
import UIKit

/// The app's colours, in one place.
///
/// Black, like a chart on a trading terminal: a near-black ground, cards one
/// step up, light ink, hairline rules — and a single clay accent that carries
/// every action. Colour is scarce on purpose: when almost nothing is coloured,
/// the one thing that is (a reply, a warning, the accent on a button) is read
/// first. `grid` is the faint graph-paper rule the whole app is drawn on.
///
/// There is one appearance. The app forces dark (`RootView`), so system chrome
/// — sheets, alerts, keyboards, glass — agrees with these values everywhere.
enum Palette {

    // MARK: - Ground and surfaces

    /// The page. Everything else sits on this.
    static let paper = Color(hex: 0x09090B)

    /// A raised surface: cards, panels, rows.
    static let paperRaised = Color(hex: 0x151518)

    /// A recessed surface: the trough of a control, a segmented track. Lighter
    /// than the ground, not darker — on black, a well has to be lit to be seen.
    static let paperSunken = Color(hex: 0x1C1C20)

    // MARK: - Ink

    /// Primary text.
    static let ink = Color(hex: 0xF4F4F5)
    /// Secondary text: captions, subtitles, the second line of a row.
    static let inkMuted = Color(hex: 0x9D9DA6)
    /// Tertiary text: chevrons, timestamps, anything you should be able to ignore.
    static let inkFaint = Color(hex: 0x62626B)

    /// Hairline rules and card borders. Carries structure so shadows don't have to.
    static let hairline = Color(hex: 0x27272C)

    /// Graph-paper rules behind every screen and inside every chart.
    static let grid = Color(hex: 0x17171B)

    // MARK: - Accent and status

    /// The one accent: clay. Buttons, selection, the active state, the curve.
    static let clay = Color(hex: 0xE8794F)
    /// A reply landed.
    static let olive = Color(hex: 0x8CC47E)
    /// Sent, waiting, in progress. Cool enough to read as neutral beside clay.
    static let slate = Color(hex: 0x8EA8CC)
    /// Set aside or needs attention: bounced, invalid, unmigrated.
    static let kraft = Color(hex: 0xE0AA6E)
    /// Destructive and broken: delete, a template that won't render.
    static let danger = Color(hex: 0xF0705F)
}

/// The palette as `Color` members, so `Color.clay` reads naturally in a fill.
extension Color {
    static var paper: Color { Palette.paper }
    static var paperRaised: Color { Palette.paperRaised }
    static var paperSunken: Color { Palette.paperSunken }
    static var ink: Color { Palette.ink }
    static var inkMuted: Color { Palette.inkMuted }
    static var inkFaint: Color { Palette.inkFaint }
    static var hairline: Color { Palette.hairline }
    static var grid: Color { Palette.grid }
    static var clay: Color { Palette.clay }
    static var olive: Color { Palette.olive }
    static var slate: Color { Palette.slate }
    static var kraft: Color { Palette.kraft }
    static var danger: Color { Palette.danger }
}

/// And in `ShapeStyle` position, so `.foregroundStyle(.inkMuted)` reads as
/// naturally as the system's `.secondary` it replaces. Both forward to
/// ``Palette`` by name rather than to each other — when these were mutually
/// referential, only Swift's preference for concrete members over protocol
/// extensions kept it from recursing forever.
extension ShapeStyle where Self == Color {
    static var paper: Color { Palette.paper }
    static var paperRaised: Color { Palette.paperRaised }
    static var paperSunken: Color { Palette.paperSunken }
    static var ink: Color { Palette.ink }
    static var inkMuted: Color { Palette.inkMuted }
    static var inkFaint: Color { Palette.inkFaint }
    static var hairline: Color { Palette.hairline }
    static var grid: Color { Palette.grid }
    static var clay: Color { Palette.clay }
    static var olive: Color { Palette.olive }
    static var slate: Color { Palette.slate }
    static var kraft: Color { Palette.kraft }
    static var danger: Color { Palette.danger }
}

extension Color {
    /// A colour from its hex value, spelled out so the palette can be diffed
    /// against design values directly.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Type

extension Font {
    /// Editorial headings and figures, set in the system serif. Reserved for
    /// titles and for numbers that are the point of the screen — a serif numeral
    /// among sans labels reads as a headline without needing to be large.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - App-wide chrome

enum AppAppearance {
    /// Set navigation titles in the serif, so a screen's title matches the
    /// headings and figures on the screen below it.
    ///
    /// Called once at launch. Doing it through the appearance proxy rather than
    /// per-screen modifiers keeps every bar in the app in step, including the ones
    /// pushed inside sheets.
    static func apply() {
        // Only the type is overridden, through the bar's own properties. Handing
        // iOS 26 a fully configured `UINavigationBarAppearance` here made the
        // large title stop drawing altogether — the space was reserved and left
        // empty — so the background and materials are left to the system, which
        // already paints them to match the page.
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: serif(size: 34, weight: .bold)
        ]
        UINavigationBar.appearance().titleTextAttributes = [
            .font: serif(size: 17, weight: .semibold)
        ]
    }

    /// The system serif at a given size, falling back to the default face if the
    /// serif descriptor isn't available.
    private static func serif(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
