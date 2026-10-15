import Foundation

/// What the user can ask the on-device model to do with a piece of writing, and
/// the checks that keep it from damaging a mail. Kept apart from the model call
/// itself (`WritingAssistant`) so the rules can be tested without Apple
/// Intelligence.
enum WritingAction: String, CaseIterable, Identifiable {
    case proofread, rewrite, friendlier, professional, shorter, longer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proofread: "Proofread"
        case .rewrite: "Rewrite"
        case .friendlier: "Make friendlier"
        case .professional: "Make more professional"
        case .shorter: "Make shorter"
        case .longer: "Expand"
        }
    }

    var systemImage: String {
        switch self {
        case .proofread: "checkmark.circle"
        case .rewrite: "arrow.triangle.2.circlepath"
        case .friendlier: "face.smiling"
        case .professional: "briefcase"
        case .shorter: "arrow.down.right.and.arrow.up.left"
        case .longer: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// The instruction for this action.
    var instruction: String {
        switch self {
        case .proofread:
            "Fix spelling, grammar and punctuation only. Keep every word that is spelled correctly, including greetings, and do not change the tone or length."
        case .rewrite:
            "Rewrite it so it reads more clearly and naturally, keeping the same meaning and roughly the same length."
        case .friendlier:
            "Rewrite it in a warmer, friendlier tone, keeping the same meaning and roughly the same length."
        case .professional:
            "Rewrite it in a more polished, professional tone, keeping the same meaning and roughly the same length."
        case .shorter:
            "Make it noticeably shorter and tighter without losing the main point."
        case .longer:
            "Expand it a little with more detail and smoother flow, using only what it already says."
        }
    }

    /// The rules every request carries, so the model treats the text as a mail
    /// to leave intact in structure, not a chat to answer. `known` are the
    /// placeholders the app understands; the model may add those if asked, and
    /// no others.
    static func rules(known: [String] = []) -> String {
        var rules = """
            You edit short emails that a student sends to recruiters. \
            Reply with the edited text only: no preface, no quotation marks, no notes. \
            Keep every placeholder in curly braces, such as {Receiver-Name}, exactly as written and in a sensible place. \
            Keep line breaks and paragraphs. \
            Keep the opening greeting and the closing line unless the instruction asks to change them. \
            Do not delete words except to carry out the instruction. \
            Never invent facts, names, numbers or links, and never add a greeting or sign-off that isn't already there \
            unless the instruction asks for one.
            """
        if !known.isEmpty {
            rules += " If the instruction asks for a name, company, role or link to be included, you may use these placeholders and no others: "
                + known.joined(separator: ", ") + "."
        }
        return rules
    }

    func prompt(for text: String) -> String {
        "\(instruction)\n\nText:\n\(text)"
    }

    /// The user's own instruction for the text, in their words.
    static func customPrompt(_ instruction: String, for text: String) -> String {
        """
        Apply this instruction to the text: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))

        Text:
        \(text)
        """
    }

    /// Instructions for drafting a company line from scratch.
    static func draftPrompt(company: String, sector: String?, website: String?) -> String {
        var facts = "Company: \(company)"
        if let sector, !sector.isEmpty { facts += "\nSector: \(sector)" }
        if let website, !website.isEmpty { facts += "\nWebsite: \(website)" }
        return """
            Write one or two sentences, in the first person, for a student's cold email to a recruiter at this company, \
            saying genuine interest in the company. Use only the facts below; do not invent products, projects, news or numbers. \
            If little is known, stay general about the sector.

            \(facts)
            """
    }

    // MARK: - Checks

    /// The `{…}` runs in `text`, sorted, for comparing before and after.
    static func placeholders(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "\\{[^{}]*\\}")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .sorted()
    }

    /// Whether `result` still carries every placeholder `original` did, and
    /// adds none the app doesn't know. A rewrite that drops, renames or invents
    /// one would send a mail with a blank where a name goes, or a token
    /// printed as text.
    static func keepsPlaceholders(original: String, result: String, allowing known: [String] = []) -> Bool {
        var remaining = placeholders(in: result)
        for token in placeholders(in: original) {
            guard let index = remaining.firstIndex(of: token) else { return false }
            remaining.remove(at: index)
        }
        return remaining.allSatisfy(known.contains)
    }

    /// The model's reply without the wrapping it sometimes adds: surrounding
    /// whitespace, a code fence, or quotes around the whole text.
    static func cleaned(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”")]
        where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2
            && !text.dropFirst().dropLast().contains(open) {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
