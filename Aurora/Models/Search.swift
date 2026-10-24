import Foundation

/// A search as typed, folded once: lowercased, accents and widths dropped, and
/// split into words. Every word has to turn up somewhere in what's searched, in
/// any order — "juniper chloe" finds Chloe at Juniper Cloud, which a whole-query
/// match across one field at a time never could.
///
/// Matching runs on text folded the same way (`String.searchFolded`), with the
/// standard library's `contains` rather than `localizedCaseInsensitiveContains`:
/// the localized test re-folds both strings through ICU on every call, which over
/// thousands of contacts per keystroke was most of a search's time.
nonisolated struct SearchQuery: Sendable, Equatable {
    let words: [String]

    /// Nil for a query that's empty once trimmed: "no query" is the caller's
    /// decision, not a filter that matches everything.
    init?(_ raw: String) {
        let words = raw.searchFolded
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        self.words = words
    }

    /// Whether every word is in `folded`, which must already be `searchFolded`.
    func matches(folded: String) -> Bool {
        words.allSatisfy { folded.contains($0) }
    }

    /// Whether every word is in one of `fields`, not necessarily the same one.
    /// Folds each field as it goes; for text searched again and again, fold it
    /// once and use `matches(folded:)`.
    func matches(_ fields: String?...) -> Bool {
        matches(folded: Self.haystack(fields))
    }

    /// Fields joined into one folded string to search. A separator no folded
    /// word can contain keeps "ab" from matching the end of one field and the
    /// start of the next.
    static func haystack(_ fields: [String?]) -> String {
        fields.lazy.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\u{1F}").searchFolded
    }
}

extension String {
    /// This text as searches compare it: case, accents and full/half widths
    /// folded away, so "José" is found by "jose" and "ＡＢＣ" by "abc".
    nonisolated var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Folded search text for each company, kept between keystrokes. A company's
/// text is folded again only when something it's searched by changes, which the
/// cache tells by a hash of those fields — hashing is far cheaper than folding.
nonisolated final class SearchTextCache: @unchecked Sendable {
    static let shared = SearchTextCache()

    private let lock = NSLock()
    private var entries: [String: (signature: Int, text: String)] = [:]

    /// The folded text for `id`, folding `fields` only when their signature
    /// differs from the one last seen.
    func text(for id: String, signature: Int, fields: () -> [String?]) -> String {
        lock.lock()
        if let entry = entries[id], entry.signature == signature {
            lock.unlock()
            return entry.text
        }
        lock.unlock()
        let text = SearchQuery.haystack(fields())
        lock.lock()
        // A catalog only ever grows by pages, but a long session can scroll a
        // lot of it; past this, start over rather than hold every company.
        if entries.count > 20_000 { entries.removeAll(keepingCapacity: true) }
        entries[id] = (signature, text)
        lock.unlock()
        return text
    }
}
