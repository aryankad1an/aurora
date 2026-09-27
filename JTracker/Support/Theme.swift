import SwiftUI

/// Shared design tokens so spacing, sizing, and semantic color usage stay
/// consistent across every screen instead of being re-picked ad hoc per view.
enum Theme {
    /// Avatar diameters. `medium` for primary list rows, `small` for dense or
    /// secondary contexts.
    enum Avatar {
        static let small: CGFloat = 36
        static let medium: CGFloat = 44
    }
}

extension ShapeStyle where Self == Color {
    /// Positive / completed states: a reply landed, Gmail connected.
    static var statusDone: Color { .olive }

    /// Set-aside states: a contact marked invalid, an address that bounced.
    /// Deliberately not red — nothing has been destroyed, and red is reserved for
    /// delete.
    static var statusInvalid: Color { .kraft }

    /// Mailed, no answer yet — neutral, not a failure.
    static var statusWaiting: Color { .slate }
}

extension Color {
    /// A stable accent color derived from `text`, so the same name always gets the
    /// same color everywhere it appears — an avatar, a filter chip, the tint of a
    /// timeline card — and those readings agree with each other.
    ///
    /// The bucket comes from a djb2 hash rather than a sum of code points: summing
    /// barely mixes the low bits, so real names (similar lengths, overlapping
    /// letters) collided in visible clumps — a list would show the same color three
    /// rows running. Swift's own `hashValue` isn't an option, since it's seeded per
    /// process and would repaint every avatar on each launch.
    /// The palette is muted on purpose. Saturated system colours turned a list of
    /// contacts into a bag of sweets and drowned the two colours that carry
    /// meaning here — clay for actions, olive for replies. These are desaturated
    /// enough to sit under the accent while still telling two rows apart, and
    /// mid-toned enough to hold white text in either appearance.
    static func monogram(for text: String) -> Color {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return monogramPalette[Int(hash % UInt64(monogramPalette.count))]
    }

    /// Built once, not per avatar drawn.
    private static let monogramPalette: [Color] = [
        Color(red: 0.62, green: 0.36, blue: 0.24),   // clay
        Color(red: 0.42, green: 0.47, blue: 0.36),   // olive
        Color(red: 0.35, green: 0.44, blue: 0.53),   // slate
        Color(red: 0.55, green: 0.40, blue: 0.47),   // plum
        Color(red: 0.63, green: 0.51, blue: 0.30),   // kraft
        Color(red: 0.31, green: 0.48, blue: 0.47),   // teal
        Color(red: 0.48, green: 0.42, blue: 0.56),   // iris
        Color(red: 0.58, green: 0.34, blue: 0.33)    // rust
    ]
}

extension String {
    /// Swap stray Unicode line/paragraph separators (U+2028, U+2029, U+0085) for
    /// a plain space.
    ///
    /// iOS's keyboard (swipe-typing and predictive text in particular) will
    /// occasionally emit one of these instead of an ordinary space when the tap
    /// or swipe lands right on a soft line-wrap boundary in a multi-line text
    /// view. They're invisible in the editor — indistinguishable from a normal
    /// space on screen — but mail is sent as `text/plain`, where every mail
    /// client (Gmail included) honors them as a hard line break, same as a real
    /// "\n". So a paragraph that only ever wrapped on screen can arrive with an
    /// unintended break in it even though the sender never pressed Return.
    /// Actual "\n"/"\n\n" from a real Return keypress are left untouched.
    var sanitizedLineSeparators: String {
        replacingOccurrences(of: "[\u{2028}\u{2029}\u{0085}]", with: " ", options: .regularExpression)
    }
}

extension String {
    /// Undo HTML escaping.
    ///
    /// Gmail's `snippet` is HTML — it comes out of the message body, so an
    /// apostrophe arrives as `&#39;` and an ampersand as `&amp;`. Shown raw, a
    /// contact's "We've noted your profile" reads as "We&#39;ve noted", which
    /// looks like the app is broken rather than like a quote.
    ///
    /// Deliberately a small table plus numeric references rather than
    /// `NSAttributedString(html:)`: that initialiser spins up WebKit, must run on
    /// the main actor, and is far too heavy for one line of preview text.
    nonisolated var htmlUnescaped: String {
        guard contains("&") else { return self }

        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
                     "&ndash;": "–", "&rsquo;": "'", "&lsquo;": "'",
                     "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"]

        var result = self
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character,
                                                 options: .caseInsensitive)
        }

        // Numeric references: &#39; and &#x2019; alike.
        let pattern = /&#(x?)([0-9A-Fa-f]+);/
        while let match = result.firstMatch(of: pattern) {
            let radix = match.1.isEmpty ? 10 : 16
            guard let code = UInt32(match.2, radix: radix),
                  let scalar = Unicode.Scalar(code) else {
                // Unrepresentable: drop the reference rather than looping forever.
                result.replaceSubrange(match.range, with: "")
                continue
            }
            result.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return result
    }
}

extension String {
    /// A reply's opening lines without the quoted mail after them. Gmail's
    /// snippet runs straight on from the answer into the quote header —
    /// "…please apply! On Wed, Sep 2, 2026 at 6:21 AM Aryan Kadian" — and that
    /// tail is the sender's own mail, not what they were told. Gmail's, Apple
    /// Mail's and Outlook's header shapes are recognised; a snippet that is
    /// nothing but a header is left as it is.
    var withoutQuoteHeader: String {
        let header = #"(?s)\s+On\s+(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?|\d{1,2}\s+[A-Z][a-z]+\.?,?\s+\d{4},?|[A-Z][a-z]+\.?\s+\d{1,2},?\s+\d{4},?)\s.*$"#
        guard let range = range(of: header, options: .regularExpression) else { return self }
        let answer = self[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? self : answer
    }
}

extension Date {
    /// A compact, human label for activity timestamps:
    /// "Today", "Yesterday", "Aug 12", or "Aug 12, 2025" outside the current year.
    var activityLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// `activityLabel` for the middle of a sentence — "sent today", "sent Aug
    /// 12". Only the relative words drop their capital; lowercasing the whole
    /// label turned months into "aug".
    var activityPhrase: String {
        let cal = Calendar.current
        return cal.isDateInToday(self) || cal.isDateInYesterday(self)
            ? activityLabel.lowercased() : activityLabel
    }
}
