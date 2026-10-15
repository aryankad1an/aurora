import Foundation

/// A word-level comparison of two versions of a text, for showing what an AI
/// edit changed before it's accepted.
struct TextDiff {
    enum Kind { case same, added, removed }

    struct Segment: Equatable {
        let kind: Kind
        let text: String
    }

    let segments: [Segment]

    /// Words added and removed, ignoring spacing, for a one-line summary.
    let addedWords: Int
    let removedWords: Int

    var hasChanges: Bool { addedWords > 0 || removedWords > 0 || segments.contains { $0.kind != .same } }

    init(from old: String, to new: String) {
        let a = Self.tokens(old), b = Self.tokens(new)
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        var segments: [Segment] = []
        func append(_ kind: Kind, _ text: String) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = Segment(kind: kind, text: last.text + text)
            } else {
                segments.append(Segment(kind: kind, text: text))
            }
        }
        var i = 0, j = 0
        var added = 0, removed = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                append(.removed, a[i])
                if !a[i].allSatisfy(\.isWhitespace) { removed += 1 }
                i += 1
            } else if j < b.count, insertedAt.contains(j) {
                append(.added, b[j])
                if !b[j].allSatisfy(\.isWhitespace) { added += 1 }
                j += 1
            } else {
                append(.same, b[j])
                i += 1
                j += 1
            }
        }
        self.segments = segments
        self.addedWords = added
        self.removedWords = removed
    }

    /// Words and the runs of whitespace between them, as separate tokens, so a
    /// change in spacing shows as one and a changed word doesn't drag its
    /// neighbours' spaces along.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSpace: Bool?
        for character in text {
            let space = character.isWhitespace
            if inSpace == nil || inSpace == space {
                current.append(character)
            } else {
                tokens.append(current)
                current = String(character)
            }
            inSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
