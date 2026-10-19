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

    /// The title on a quick-fix tile, where "Make" on four of them is noise.
    var shortTitle: String {
        switch self {
        case .friendlier: "Friendlier"
        case .professional: "Professional"
        case .shorter: "Shorter"
        default: title
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

    /// The instruction for this action. Each says what to keep as well as what to
    /// change: asked only to "rewrite", the on-device model drops greetings and
    /// invents subject lines.
    var instruction: String {
        switch self {
        case .proofread:
            "Fix spelling, grammar and punctuation only. Change nothing else."
        case .rewrite:
            "Rewrite the email so it is clearer and more natural. Keep the meaning and the length similar."
        case .friendlier:
            "Make the tone warmer and friendlier. Keep the meaning and the length similar."
        case .professional:
            "Make the tone more polished and professional. Keep the meaning and the length similar."
        case .shorter:
            "Make the email shorter and tighter. Keep every placeholder and the main point."
        case .longer:
            "Make the email a little longer: add one or two natural sentences that elaborate on what it already says, such as why the sender is interested in the role. Do not claim anything the sender has done, and add no new facts about the sender or the company."
        }
    }

    /// What an instruction left empty asks for: a general tidy-up for wherever
    /// the text is going, which the brief ahead of it says.
    static let polishInstruction = "Polish the email for where it is going: fix any mistakes, make awkward sentences clearer and more natural, and tighten anything wordy. Keep the meaning, every fact and roughly the same length."

    /// How freely the model may vary, 0 to 1. Proofreading should read the same
    /// every time; a rewrite that is asked for again should come out differently.
    var temperature: Double {
        switch self {
        case .proofread: 0.1
        case .rewrite, .friendlier, .professional, .shorter: 0.4
        case .longer: 0.6
        }
    }

    /// The rules every edit carries. Short and mostly positive: the on-device
    /// model follows a few clear rules better than a long list of prohibitions.
    ///
    /// For a template, `known` placeholders are explained and shown in use, so
    /// "mention my college" writes `{Sender-College}` instead of nothing. For a
    /// mail that is already filled in, `senderFacts` are the real details to use.
    /// `isLine` is for the company line, which is a sentence or two that sits in
    /// the middle of a mail, not a mail: under the email rules the model wrapped
    /// it in a greeting and a sign-off.
    static func rules(known: [String] = [], senderFacts: String? = nil, isLine: Bool = false) -> String {
        if isLine {
            return """
                You edit one or two sentences that go in the middle of a student's job-outreach email to a recruiter.
                You receive the sentences and an instruction. Reply with the revised sentences only: no explanation, no quotation marks.
                - Do exactly what the instruction says.
                - Write in the first person.
                - Do not add a greeting, a sign-off, a subject line or anything in curly braces.
                - Do not invent facts, names, numbers or links.
                - If nothing needs changing, return the sentences unchanged.
                """
        }
        var rules = """
            You are a careful copy editor for short job-outreach emails written by a student.
            You receive an email and an instruction. Reply with the revised email only: no explanation, no quotation marks, no code fences.
            - Do exactly what the instruction says, including adding the detail it asks for. If it asks for several things, do every one of them.
            - Keep each placeholder in curly braces, such as {Receiver-Name}, exactly as written.
            - Keep the paragraph structure and line breaks.
            - Keep the greeting and the closing line as they are, unless the instruction is about them.
            - Do not add a subject line, a greeting or a sign-off unless the instruction asks for one.
            - Do not invent facts, names, numbers or links.
            - If nothing needs changing, return the email unchanged.
            """
        if !known.isEmpty {
            rules += """


                To refer to a detail of the sender or recipient, write its placeholder: \
                the recipient's first name {Receiver-Name}, their job title {Receiver-Position}, their company {Receiver-Company}, \
                the sender's name {Sender-Name}, college {Sender-College}, employer {Sender-Company}, job title {Sender-Position}, \
                resume link {Resume-Link}. Use only these placeholders: \(known.joined(separator: ", ")).
                A request to mention, share, attach or point to the resume or CV means writing {Resume-Link} in a sentence. \
                A request to introduce the sender means writing {Sender-Name}.
                {Company-Personalised} is a whole sentence about the company, written separately for each recipient. \
                Leave it where it is, as a sentence of its own; never use it as a name or part of a sentence.

                Example
                Instruction: Mention my college
                Email:
                Hi {Receiver-Name},

                I'm interested in the analyst role.

                Thanks for your time.
                Revised:
                Hi {Receiver-Name},

                I'm a student at {Sender-College} and I'm interested in the analyst role.

                Thanks for your time.

                Example
                Instruction: Point to my resume
                Email:
                Hello {Receiver-Name},

                I'd like to join your team.

                Regards
                Revised:
                Hello {Receiver-Name},

                I'd like to join your team. My resume is here: {Resume-Link}

                Regards
                """
        }
        if let senderFacts, !senderFacts.isEmpty {
            rules += """


                Details about the sender, to use when the instruction asks for them: \(senderFacts)

                Example
                Details: studies at Anna University
                Instruction: Mention my college
                Email:
                Hi Rahul,

                I'm interested in the analyst role.
                Revised:
                Hi Rahul,

                I'm a student at Anna University and I'm interested in the analyst role.
                """
        }
        return rules
    }

    /// The rules for writing a company line from scratch. Their own, because under
    /// the editing rules the model answered with a whole email: a greeting, a
    /// sign-off, and placeholders of its own invention.
    ///
    /// Two sets, by whether the student gave notes. With generic examples in the
    /// rules the model copies them and ignores the notes, so notes get rules and
    /// examples built around them alone. Without notes, the student's own
    /// details (`hasStudent`) let the line say why them, not just why the company.
    static func draftRules(hasNotes: Bool, hasStudent: Bool = false) -> String {
        let common = """
            You write one or two sentences for a student's cold email to a recruiter at a company.
            Reply with those sentences only: no greeting, no sign-off, no quotation marks, no curly braces.
            Write in the first person. Use the company's name exactly as given, and never mention its website.
            Never invent products, projects, news or numbers.
            """
        if hasNotes {
            return common + """


                The student's notes are what the sentences are about. Say what the notes say, in natural words, \
                and end by saying you'd like to learn more. Add no facts of your own.

                Example
                Company: Notion
                Notes from the student: I use Notion daily and rebuilt my college's club wiki in it
                Reply: I use Notion every day and rebuilt my college's club wiki in it, so I'd love to learn how your team approaches the product.

                Example
                Company: Razorpay
                Sector: Payments
                Notes from the student: built a checkout demo with their API, curious about fraud checks
                Reply: I built a checkout demo with Razorpay's API and became curious about how fraud checks work, so I'd love to learn more about how your team approaches payments.
                """
        }
        if hasStudent {
            return common + """


                Say why the student is interested in the company and its work, and tie in what the student studies \
                or does where it fits naturally. Use only the facts given about the student, and nothing more about \
                their background, skills or experience.

                Example
                Company: Notion
                Sector: Productivity software
                About the student: studies at Anna University
                Reply: As a student at Anna University, I'm excited by the work Notion is doing in productivity software, and I'd love to learn more about how your team builds it.
                """
        }
        return common + """

            Say the student is interested in the company and its work. Use only the facts given, and say nothing about the \
            student's background, skills or experience.

            Example
            Company: Notion
            Sector: Productivity software
            Reply: I'm excited by the work Notion is doing in productivity software, and I'd love to learn more about how your team builds it.

            Example
            Company: Rippling
            Reply: Rippling's work really interests me, and I'd welcome the chance to learn more about your team.
            """
    }

    func prompt(for text: String, isLine: Bool = false) -> String {
        Self.editPrompt(instruction, for: text, isLine: isLine)
    }

    /// An instruction and the text it applies to. For a company line the
    /// instruction is worded for a sentence: "make the email shorter" reads as
    /// a reason to write a whole email.
    static func editPrompt(_ instruction: String, for text: String, isLine: Bool = false) -> String {
        let task = isLine
            ? instruction.replacingOccurrences(of: "the email", with: "the sentences")
                .replacingOccurrences(of: "Keep every placeholder and ", with: "Keep ")
            : instruction
        return "Instruction: \(task.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(isLine ? "Sentences" : "Email"):\n\(text)"
    }

    /// What a company line is written from: the company, its sector if known,
    /// what the student studies or does, and anything they said they want it to say. The website is left out on
    /// purpose — given it, the model announces that it found it.
    static func draftPrompt(company: String, sector: String?, notes: String?, student: String? = nil) -> String {
        var prompt = "Company: \(company)"
        if let sector, !sector.isEmpty { prompt += "\nSector: \(sector)" }
        if let student = student?.trimmingCharacters(in: .whitespacesAndNewlines), !student.isEmpty {
            prompt += "\nAbout the student: \(student)"
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            prompt += "\nNotes from the student: \(notes)"
        }
        return prompt + "\nReply:"
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

    /// A drafted company line without anything that would not read as one in the
    /// middle of a mail: a stray greeting or sign-off line from the email-shaped
    /// answers the model leans towards, and braces of its own invention.
    static func cleanedLine(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            // Everything from a sign-off on is the signature, name included.
            // Short only: "Thanks to its API, I built…" is a sentence, not a sign-off.
            let isShort = lower.split(separator: " ").count <= 3
            if isShort, ["best regards", "regards", "thanks", "thank you", "sincerely", "best,"].contains(where: lower.hasPrefix) { break }
            if lower.hasPrefix("hi ") || lower.hasPrefix("hello") || lower.hasPrefix("dear ") { continue }
            kept.append(line)
        }
        let joined = kept.joined(separator: " ")
        // A line holding braces is the model improvising placeholders; nothing is
        // better than a mail that prints "{company-name}".
        return joined.contains("{") || joined.contains("}") ? "" : joined
    }

    /// The model's reply without the wrapping it sometimes adds: surrounding
    /// whitespace, a code fence, or quotes around the whole text.
    static func cleaned(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // The worked examples in the rules end in "Revised:" and "Reply:", which
        // the model sometimes echoes before its answer.
        for label in ["Revised:", "Reply:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
