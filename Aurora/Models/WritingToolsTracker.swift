import Foundation

/// What one pass of the system's Writing Tools did to a piece of text.
struct WritingToolsChange: Identifiable, Equatable {
    let id = UUID()
    let before: String
    let after: String

    var diff: TextDiff { TextDiff(from: before, to: after) }
}

/// Notices when Writing Tools has finished changing a text view, from samples of
/// "is it active" and "what does the text say" taken as the screen runs.
///
/// Writing Tools edits the text in place, so the app can't intercept the change;
/// it can only see that the panel closed and the text is different from what it
/// was before it opened. The text is remembered while the panel is closed and
/// frozen while it's open, so on closing, `stable` is exactly what the user had
/// before — and anything they type in between is simply the new baseline.
struct WritingToolsTracker {
    private var stable: String
    private var wasActive = false

    init(text: String = "") { stable = text }

    /// Feed one sample. Returns the change the moment Writing Tools closes with the
    /// text different from how it opened.
    mutating func observe(isActive: Bool, text: String) -> WritingToolsChange? {
        defer { wasActive = isActive }
        if isActive { return nil }
        let change = wasActive && text != stable ? WritingToolsChange(before: stable, after: text) : nil
        stable = text
        return change
    }
}

/// Placeholders in curly braces that a change removed or invented. Writing Tools
/// knows nothing of `{Receiver-Name}`; a rewrite can respell it, drop it, or
/// write one of its own, and the mail would go out with a blank or a literal token.
struct PlaceholderDamage: Equatable {
    var removed: [String]
    var added: [String]

    var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    init(before: String, after: String) {
        var remaining = Self.placeholders(in: after)
        var removed: [String] = []
        for token in Self.placeholders(in: before) {
            if let index = remaining.firstIndex(of: token) { remaining.remove(at: index) } else { removed.append(token) }
        }
        self.removed = removed
        self.added = remaining
    }

    /// The `{…}` runs in `text`, in order.
    static func placeholders(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "\\{[^{}]*\\}")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
