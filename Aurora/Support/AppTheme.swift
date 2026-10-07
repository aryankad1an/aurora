import SwiftUI
import UIKit

/// The app's looks. Each theme is a whole identity, not a tint: its own ground
/// and ink, its own accent, its own moving chart behind every screen, its own
/// mark on the splash and its own app icon.
///
/// Every theme is dark. The app forces dark chrome (`RootView`), so sheets,
/// alerts, keyboards and glass agree with any of these grounds without a second
/// set of values.
struct AppTheme: Identifiable, Equatable {
    enum ID: String, CaseIterable, Identifiable {
        case aurora, tide, phosphor, neon, bloom, gilded
        var id: String { rawValue }
    }

    /// The chart that moves behind every screen.
    enum Motion: Equatable {
        /// Line series drifting under a scanning cursor.
        case lines
        /// Layered swells rolling across the lower half.
        case waves
        /// A candlestick chart scrolling past, with its moving average.
        case candles
        /// A neon line over a perspective grid running toward you.
        case neon
        /// A scatter plot drifting upward, like petals in warm air.
        case scatter
        /// A radar sweep turning over concentric rings.
        case radar
    }

    let id: ID
    let name: String
    /// One line under the wordmark on the splash, and under the name in Settings.
    let tagline: String
    let palette: ThemePalette
    let motion: Motion
    /// The mark: the glyph in the splash's lens and on the sign-in screen.
    let mark: String
    /// The alternate app icon's name; nil is the primary icon.
    let iconName: String?

    /// The icon as an image the app can draw (alternate icons can't be read
    /// back from the bundle by name).
    var iconPreview: String { "ThemeIcon-\(id.rawValue)" }

    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool { lhs.id == rhs.id }
}

/// A theme's colours, named for what they do. ``Palette`` forwards to the
/// current theme's.
struct ThemePalette {
    let paper, paperRaised, paperSunken: Color
    let ink, inkMuted, inkFaint: Color
    let hairline, grid: Color
    /// The one accent: actions, selection, the curve.
    let accent: Color
    /// A reply landed.
    let reply: Color
    /// Sent, waiting, in progress.
    let waiting: Color
    /// Set aside: bounced, invalid.
    let attention: Color
    /// Delete, broken.
    let danger: Color
}

extension AppTheme {
    static let all: [AppTheme] = [aurora, tide, phosphor, neon, bloom, gilded]

    static func theme(_ id: ID) -> AppTheme {
        all.first { $0.id == id } ?? aurora
    }

    /// The original: a trading terminal at night, one clay accent.
    static let aurora = AppTheme(
        id: .aurora, name: "Aurora", tagline: "Charting your outreach",
        palette: ThemePalette(
            paper: Color(hex: 0x09090B), paperRaised: Color(hex: 0x151518), paperSunken: Color(hex: 0x1C1C20),
            ink: Color(hex: 0xF4F4F5), inkMuted: Color(hex: 0x9D9DA6), inkFaint: Color(hex: 0x62626B),
            hairline: Color(hex: 0x27272C), grid: Color(hex: 0x17171B),
            accent: Color(hex: 0xE8794F), reply: Color(hex: 0x8CC47E), waiting: Color(hex: 0x8EA8CC),
            attention: Color(hex: 0xE0AA6E), danger: Color(hex: 0xF0705F)),
        motion: .lines, mark: "paperplane.fill", iconName: nil)

    /// Deep water, a teal crest.
    static let tide = AppTheme(
        id: .tide, name: "Tide", tagline: "Ride the reply wave",
        palette: ThemePalette(
            paper: Color(hex: 0x061014), paperRaised: Color(hex: 0x0D1A20), paperSunken: Color(hex: 0x12232B),
            ink: Color(hex: 0xEAF6F8), inkMuted: Color(hex: 0x8FB1BA), inkFaint: Color(hex: 0x557782),
            hairline: Color(hex: 0x18303A), grid: Color(hex: 0x0C1C22),
            accent: Color(hex: 0x3CC8C8), reply: Color(hex: 0x7FD89A), waiting: Color(hex: 0x86A8E6),
            attention: Color(hex: 0xE6B66E), danger: Color(hex: 0xF2706A)),
        motion: .waves, mark: "water.waves", iconName: "AppIcon-Tide")

    /// A green-phosphor terminal.
    static let phosphor = AppTheme(
        id: .phosphor, name: "Phosphor", tagline: "Signal over noise",
        palette: ThemePalette(
            paper: Color(hex: 0x050A06), paperRaised: Color(hex: 0x0C140E), paperSunken: Color(hex: 0x111C13),
            ink: Color(hex: 0xD8F5DC), inkMuted: Color(hex: 0x86A98C), inkFaint: Color(hex: 0x4E6B53),
            hairline: Color(hex: 0x173020), grid: Color(hex: 0x0B170E),
            accent: Color(hex: 0x3BE477), reply: Color(hex: 0x5EE0D6), waiting: Color(hex: 0x9BB8A6),
            attention: Color(hex: 0xE8C35A), danger: Color(hex: 0xFF6B5E)),
        motion: .candles, mark: "terminal.fill", iconName: "AppIcon-Phosphor")

    /// Synthwave: magenta over a violet night.
    static let neon = AppTheme(
        id: .neon, name: "Neon", tagline: "Outreach after dark",
        palette: ThemePalette(
            paper: Color(hex: 0x0B0614), paperRaised: Color(hex: 0x150D22), paperSunken: Color(hex: 0x1C1230),
            ink: Color(hex: 0xF5EEFF), inkMuted: Color(hex: 0xA898C4), inkFaint: Color(hex: 0x6A5A88),
            hairline: Color(hex: 0x2A1B44), grid: Color(hex: 0x150C26),
            accent: Color(hex: 0xFF3EA5), reply: Color(hex: 0x3EE6F0), waiting: Color(hex: 0x9C8CFF),
            attention: Color(hex: 0xFFB547), danger: Color(hex: 0xFF5470)),
        motion: .neon, mark: "waveform.path.ecg", iconName: "AppIcon-Neon")

    /// Cherry blossom on plum.
    static let bloom = AppTheme(
        id: .bloom, name: "Bloom", tagline: "Let the replies blossom",
        palette: ThemePalette(
            paper: Color(hex: 0x120A0E), paperRaised: Color(hex: 0x1D1218), paperSunken: Color(hex: 0x25171F),
            ink: Color(hex: 0xFBEFF3), inkMuted: Color(hex: 0xC29AAA), inkFaint: Color(hex: 0x7E5E6B),
            hairline: Color(hex: 0x33212A), grid: Color(hex: 0x1A1015),
            accent: Color(hex: 0xF48FB1), reply: Color(hex: 0x9AD7A0), waiting: Color(hex: 0xA9B6E8),
            attention: Color(hex: 0xF1C27D), danger: Color(hex: 0xFF6F6F)),
        motion: .scatter, mark: "camera.macro", iconName: "AppIcon-Bloom")

    /// Gold leaf on black.
    static let gilded = AppTheme(
        id: .gilded, name: "Gilded", tagline: "Every reply, polished",
        palette: ThemePalette(
            paper: Color(hex: 0x0A0907), paperRaised: Color(hex: 0x16130E), paperSunken: Color(hex: 0x1E1A13),
            ink: Color(hex: 0xF6F0E2), inkMuted: Color(hex: 0xB3A88E), inkFaint: Color(hex: 0x6F6652),
            hairline: Color(hex: 0x2C261B), grid: Color(hex: 0x15120C),
            accent: Color(hex: 0xE2B34F), reply: Color(hex: 0x9FC98A), waiting: Color(hex: 0x9DB3C9),
            attention: Color(hex: 0xD9935B), danger: Color(hex: 0xEE6A5A)),
        motion: .radar, mark: "sparkle", iconName: "AppIcon-Gilded")
}

// MARK: - Store

/// The theme in force, remembered across launches.
///
/// Observable and read through ``Palette``, so any view that draws a palette
/// colour is invalidated when the theme changes — and when that change is made
/// inside an animation, every colour on screen blends to its new value rather
/// than cutting.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var current: AppTheme

    /// A change in flight: where it started on screen, and the theme it's
    /// becoming. Drives the wash that spreads from the tapped card.
    private(set) var wash: Wash?

    struct Wash: Equatable {
        let id = UUID()
        let theme: AppTheme
        let origin: CGPoint
    }

    private static let key = "appTheme"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.ID.init(rawValue:))
        current = AppTheme.theme(saved ?? .aurora)
    }

    /// Switch themes from `origin` (a point in the window): a wash of the new
    /// ground spreads out from there, the colours blend underneath it, then the
    /// home-screen icon follows.
    func apply(_ theme: AppTheme, from origin: CGPoint) {
        guard theme != current, wash == nil else { return }
        Haptics.press()
        UserDefaults.standard.set(theme.id.rawValue, forKey: Self.key)
        wash = Wash(theme: theme, origin: origin)

        Task {
            // The wash is most of the way out when the colours start to turn, so
            // the change reads as spreading from the finger rather than as a cut.
            try? await Task.sleep(for: .milliseconds(240))
            withAnimation(.smooth(duration: 0.85)) { current = theme }
            Haptics.lift(0.7)
            try? await Task.sleep(for: .milliseconds(900))
            wash = nil
            Haptics.success()
            setIcon(theme.iconName)
        }
    }

    /// The home-screen icon. iOS confirms the change with its own alert, so it
    /// waits until the in-app transition has finished.
    private func setIcon(_ name: String?) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != name else { return }
        app.setAlternateIconName(name) { _ in }
    }
}
