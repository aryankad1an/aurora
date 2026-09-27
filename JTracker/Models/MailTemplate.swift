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
    ///
    /// Also cleans up stray Unicode line separators (see `sanitizedLineSeparators`)
    /// so templates saved before that fix — which may have baked-in ones from the
    /// keyboard bug — render correctly too, not just newly-saved ones.
    func fill(_ text: String) -> String {
        MailPlaceholder.allCases.reduce(text) { result, placeholder in
            result.replacingOccurrences(of: placeholder.token, with: values[placeholder] ?? "")
        }.sanitizedLineSeparators
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
        for name in companies.sorted(by: { $0.count > $1.count }) where name.count >= 3 {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            if text.range(of: pattern, options: .regularExpression) != nil { return name }
        }
        return nil
    }
}
