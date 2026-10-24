import SwiftUI

/// The app's colours, in one place.
///
/// Retro motion graphics on pure black: neutral greys for surfaces, white ink,
/// and the burnt orange of a seventies ident carrying every action.
/// Colour is scarce on purpose: when almost nothing is coloured, the one thing
/// that is (a reply, a warning, the accent on a button) is read first. The
/// stripes are the one place the warm colours appear together, in motion.
///
/// There is one appearance. The app forces dark (`RootView`), so system
/// chrome agrees with these values everywhere. Shared with the widget
/// extension, so the widgets are drawn in the same colours.
enum Palette {
    // MARK: - Ground and surfaces

    /// The page. Everything else sits on this.
    static let paper = Color(hex: 0x000000)

    /// A raised surface: cards, panels, rows.
    static let paperRaised = Color(hex: 0x111111)

    /// A recessed surface: the trough of a control, a segmented track. Lighter
    /// than the ground, not darker — on black, a well has to be lit to be seen.
    static let paperSunken = Color(hex: 0x1C1C1C)

    // MARK: - Ink

    /// Primary text: near-white, so pure white is left for the brightest marks.
    static let ink = Color(hex: 0xF5F5F5)
    /// Secondary text: captions, subtitles, the second line of a row.
    static let inkMuted = Color(hex: 0xA6A6A6)
    /// Tertiary text: chevrons, timestamps, anything you should be able to ignore.
    static let inkFaint = Color(hex: 0x6E6E6E)

    /// Hairline rules and card borders. Carries structure so shadows don't have to.
    static let hairline = Color(hex: 0x262626)

    /// The faintest rule, inside charts.
    static let grid = Color(hex: 0x0D0D0D)

    // MARK: - Accent and status

    /// The one accent: burnt orange. Buttons, selection, the active state.
    static let clay = Color(hex: 0xF26A3D)
    /// A reply landed.
    static let olive = Color(hex: 0x74C3A5)
    /// Sent, waiting, in progress. Cool enough to read as neutral beside the accent.
    static let slate = Color(hex: 0x8DA7C2)
    /// Set aside or needs attention: bounced, invalid, unmigrated.
    static let kraft = Color(hex: 0xF2B441)
    /// Destructive and broken: delete, a template that won't render.
    static let danger = Color(hex: 0xE5483B)

    /// The ident's stripes, top to bottom: mustard, orange, vermilion, rust.
    static let stripes: [Color] = [Color(hex: 0xF2B441), Color(hex: 0xF28A3A),
                                   Color(hex: 0xE5583A), Color(hex: 0xB53F2E)]
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
