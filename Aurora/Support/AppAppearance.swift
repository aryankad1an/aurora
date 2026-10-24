import UIKit

/// App-wide chrome the palette can't reach through SwiftUI.
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
