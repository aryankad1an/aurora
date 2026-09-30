import SwiftUI
import UIKit

/// The app's haptic vocabulary, in one place.
///
/// The rule these tones encode is the same one the palette follows: feedback is
/// information. A tap that fires on everything is a tap that says nothing, so
/// each tone is tied to a *kind* of event rather than to a control —
///
/// - **`tap`** — something small answered you: a row selected, a chip picked, a
///   placeholder dropped into a template.
/// - **`press`** — you committed to something: a mode entered, a sheet advanced,
///   a batch handed off.
/// - **`thud`** — a heavier, flatter knock for the destructive edge of a swipe,
///   where the point is to feel *unlike* an ordinary tap.
/// - **`select`** — the system's detent click, for values that step through a
///   set (a segment, a filter, a lane).
/// - **`success` / `warning` / `failure`** — an outcome landed, and the phone
///   should say which one before the eye reaches the words.
/// - **`cascade`** — the one flourish: a short rising run of taps for a batch
///   that finished, so sending eight mails doesn't feel like sending one.
///
/// Generators are kept alive and re-primed after each use. A freshly-allocated
/// generator has to spin up the Taptic Engine on first play, which lands the
/// first tap of a session tens of milliseconds late — long enough to read as a
/// lag in the button rather than as feedback from it.
@MainActor
enum Haptics {

    // MARK: - Tones

    /// A light knock. The default answer to a tap that changed something.
    static func tap(_ intensity: CGFloat = 0.7) {
        light.impactOccurred(intensity: intensity)
        light.prepare()
    }

    /// A softer, rounder knock for things that *appear* rather than respond —
    /// a bar sliding up, a card popping in.
    static func lift(_ intensity: CGFloat = 0.6) {
        soft.impactOccurred(intensity: intensity)
        soft.prepare()
    }

    /// A firmer knock: you committed to something.
    static func press(_ intensity: CGFloat = 0.85) {
        medium.impactOccurred(intensity: intensity)
        medium.prepare()
    }

    /// A flat, hard knock. Reserved for the destructive edge — delete, untrack,
    /// ruling a contact out — where it should feel unlike an ordinary tap.
    static func thud() {
        rigid.impactOccurred(intensity: 1)
        rigid.prepare()
    }

    /// The detent click, for a value stepping through a set.
    static func select() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func failure() { notify(.error) }

    // MARK: - Flourishes

    /// A short rising run of taps, one per beat, for a batch that finished — a
    /// send of eight shouldn't feel identical to a send of one.
    ///
    /// Capped at five beats: past that it stops reading as a count and starts
    /// reading as a buzz, and a fifty-mail run would vibrate for a second and a
    /// half after the user had already moved on.
    static func cascade(_ steps: Int = 3) {
        let beats = min(max(steps, 1), 5)
        Task { @MainActor in
            for beat in 0..<beats {
                let intensity = 0.45 + 0.14 * CGFloat(beat)
                light.impactOccurred(intensity: min(intensity, 1))
                light.prepare()
                try? await Task.sleep(for: .milliseconds(70))
            }
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        }
    }

    /// Two quick taps — the "something arrived" knock, for replies landing after
    /// a sync. Distinct from `success`, which answers something the user just did.
    static func arrival() {
        Task { @MainActor in
            light.impactOccurred(intensity: 0.9)
            try? await Task.sleep(for: .milliseconds(90))
            medium.impactOccurred(intensity: 0.7)
            medium.prepare()
            light.prepare()
        }
    }

    /// Prime the engine ahead of a gesture that's about to produce feedback, so
    /// the first knock of a session isn't the late one.
    static func prepare() {
        light.prepare()
        medium.prepare()
        selectionGenerator.prepare()
    }

    // MARK: - Generators

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
}
