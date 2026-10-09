import Foundation

/// A reusable mail preset with placeholder tokens in its subject/content.
struct MailTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var content: String
}

/// Placeholder tokens that can be dropped into a template and later filled in.
enum MailPlaceholder: String, CaseIterable, Identifiable {
    case receiverName = "{Receiver-Name}"
    case receiverPosition = "{Receiver-Position}"
    case receiverCompany = "{Receiver-Company}"
    case senderName = "{Sender-Name}"
    case senderCollege = "{Sender-College}"
    case senderCompany = "{Sender-Company}"
    case senderPosition = "{Sender-Position}"
    case senderResume = "{Resume-Link}"

    var id: String { rawValue }
    var token: String { rawValue }

    /// Chip text in the editor. The tokens themselves are too long to read on a
    /// keyboard bar, and "Their"/"My" says which side of the mail a value comes
    /// from far faster than "Receiver"/"Sender" does.
    var shortLabel: String {
        switch self {
        case .receiverName: "Their name"
        case .receiverPosition: "Their role"
        case .receiverCompany: "Their company"
        case .senderName: "My name"
        case .senderCollege: "My college"
        case .senderCompany: "My company"
        case .senderPosition: "My role"
        case .senderResume: "Resume link"
        }
    }

    /// How a blank value is called out in the preview: "⟨their role missing⟩".
    var blankLabel: String {
        switch self {
        case .receiverName: "their name"
        case .receiverPosition: "their role"
        case .receiverCompany: "their company"
        case .senderName: "your name"
        case .senderCollege: "your college"
        case .senderCompany: "your company"
        case .senderPosition: "your role"
        case .senderResume: "resume link"
        }
    }
}

/// The concrete values used to replace placeholder tokens when composing.
struct MailContext {
    /// Maps each placeholder to the value it should be replaced with.
    var values: [MailPlaceholder: String] = [:]

    /// Replace every placeholder token in `text` with its value (empty if unset).
    /// Filling one template for many people? Parse it once with `MailText`.
    func fill(_ text: String) -> String {
        MailText(text).filled(with: self)
    }

    /// Build a context from a recipient contact, its company, and the sender profile.
    static func make(contact: Contact, company: String, profile: Profile) -> MailContext {
        MailContext(values: [
            .receiverName: contact.greeting,
            .receiverPosition: contact.position,
            .receiverCompany: company,
            .senderName: profile.name,
            .senderCollege: profile.college,
            .senderCompany: profile.company,
            .senderPosition: profile.position,
            .senderResume: profile.resumeLink
        ])
    }
}

/// Template text split once into its literal runs and placeholders, so filling
/// it in for a person is a single concatenation rather than a search of the
/// whole text per placeholder. A batch writes one template for every recipient
/// — 150 letters is 150 fills — and switching templates does it all again.
///
/// Also cleans up stray Unicode line separators (see `sanitizedLineSeparators`)
/// so templates saved before that fix — which may have baked-in ones from the
/// keyboard bug — render correctly too, not just newly-saved ones.
///
/// The spaces in front of a placeholder go with it, so one that fills in empty
/// takes them away too: with no name it can trust, "Hi {Receiver-Name}," is
/// sent as "Hi," rather than "Hi ,".
struct MailText {
    private enum Piece {
        case text(String)
        /// `lead` is the spaces or tabs that stood right before the token.
        case placeholder(MailPlaceholder, lead: String)
    }

    private let pieces: [Piece]
    /// The placeholders the text uses.
    let placeholders: Set<MailPlaceholder>

    init(_ raw: String) {
        var pieces: [Piece] = []
        var placeholders: Set<MailPlaceholder> = []
        var literalStart = raw.startIndex
        var cursor = raw.startIndex
        while let brace = raw[cursor...].firstIndex(of: "{") {
            guard let placeholder = MailPlaceholder.allCases.first(where: { raw[brace...].hasPrefix($0.token) }) else {
                cursor = raw.index(after: brace)
                continue
            }
            let literal = raw[literalStart..<brace]
            let body = literal.reversed().drop { $0 == " " || $0 == "\t" }.count
            if body > 0 {
                pieces.append(.text(String(literal.prefix(body)).sanitizedLineSeparators))
            }
            pieces.append(.placeholder(placeholder, lead: String(literal.dropFirst(body))))
            placeholders.insert(placeholder)
            cursor = raw.index(brace, offsetBy: placeholder.token.count)
            literalStart = cursor
        }
        if literalStart < raw.endIndex {
            pieces.append(.text(String(raw[literalStart...]).sanitizedLineSeparators))
        }
        self.pieces = pieces
        self.placeholders = placeholders
    }

    /// How long the filled-in text runs, in UTF-8 bytes, without writing it —
    /// enough to find the longest of many letters.
    func length(with context: MailContext) -> Int {
        pieces.reduce(0) { total, piece in
            switch piece {
            case .text(let text): total + text.utf8.count
            case .placeholder(let placeholder, let lead):
                total + (Self.value(of: placeholder, in: context).map { lead.utf8.count + $0.utf8.count } ?? 0)
            }
        }
    }

    func filled(with context: MailContext) -> String {
        var result = ""
        for piece in pieces {
            switch piece {
            case .text(let text): result += text
            case .placeholder(let placeholder, let lead):
                if let value = Self.value(of: placeholder, in: context) {
                    result += lead + value.sanitizedLineSeparators
                }
            }
        }
        return result
    }

    /// What `placeholder` fills in with, or nil when that's nothing.
    private static func value(of placeholder: MailPlaceholder, in context: MailContext) -> String? {
        guard let value = context.values[placeholder], !value.isEmpty else { return nil }
        return value
    }
}

extension MailTemplate {
    /// The company this template was written for, if it's one company's
    /// template: it names that company outright and never uses
    /// `{Receiver-Company}`. Nil for a template meant for anyone.
    ///
    /// A template like "Backend Eternal" says "roles at Eternal" in plain text.
    /// Picked for an Airbnb contact — easily, since it sorts first — it reads
    /// as the wrong company to the one person it mustn't. Knowing who it was
    /// written for is what lets the compose screen say so before it's sent.
    ///
    /// - Parameter companies: the names to look for — the companies on Home.
    ///   Matched whole-word and case-sensitively: they're proper nouns, and
    ///   "Eternal" shouldn't match "eternally grateful".
    func writtenFor(amongst companies: [String]) -> String? {
        let text = subject + "\n" + content
        guard !text.contains(MailPlaceholder.receiverCompany.token) else { return nil }
        // Longest first, so "Goldman Sachs" wins over a "Goldman" also on file.
        // A plain substring check first: it rules out nearly every company, and
        // each one it doesn't would otherwise compile a regular expression.
        for name in companies.sorted(by: { $0.count > $1.count }) where name.count >= 3 && text.contains(name) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            if text.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }
}
