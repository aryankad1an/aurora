import Foundation

/// Where the text that writing help works on ends up. The model is told this
/// before every request (`brief`), so it writes for that spot instead of
/// guessing: a template going to many recruiters, one mail about to be sent,
/// or the company line that drops into the middle of one. The sheet shows the
/// same thing to the user (`facts`), so they know what the model was told.
enum WritingPlace: Equatable {
    /// The message of a template, filled in for each recipient when it's sent.
    case template(subject: String)
    /// The message of one mail, already filled in, to one person.
    case mail(subject: String, recipient: Recipient)
    /// The personalised line for a company: what `{Company-Personalised}`
    /// becomes in mails to people there. `template` is the text of a template
    /// it sits in, so the line can be written to fit there.
    case companyLine(company: String, sector: String?, template: String?)

    struct Recipient: Equatable {
        var name: String
        var position: String
        var company: String
    }

    /// Whether the text works in placeholders such as {Receiver-Name}.
    var isTemplate: Bool {
        if case .template = self { return true }
        return false
    }

    /// The company a line is written for, which also offers drafting one.
    var draftSubject: DraftSubject? {
        guard case .companyLine(let company, let sector, _) = self else { return nil }
        return DraftSubject(company: company, sector: sector)
    }

    var ideaKind: PromptIdeas.Kind {
        switch self {
        case .template: .template
        case .mail(_, let recipient): .mail(company: recipient.company.isEmpty ? nil : recipient.company)
        case .companyLine(let company, let sector, _): .line(company: company, sector: sector)
        }
    }

    /// What accepting a change does, in the user's words.
    var destination: String {
        switch self {
        case .template: "Accepting puts this in the template's message. Save the template to keep it."
        case .mail: "Accepting puts this in the mail's message. Nothing is sent until you send it."
        case .companyLine(let company, _, _): "Accepting puts this in your line for \(company). Save to keep it."
        }
    }

    /// Where an accepted change went, and what keeps it, said briefly.
    var landing: String {
        switch self {
        case .template: "In the template. Save it to keep it."
        case .mail: "In your mail. Nothing goes until you send it."
        case .companyLine(let company, _, _): "In your line for \(company). Save to keep it."
        }
    }

    // MARK: - For the model

    /// What the text is and where it goes, put ahead of every request. Written
    /// without curly braces for the company line, whose rules forbid them: shown
    /// one, the model copies it.
    func brief(senderName: String) -> String {
        let from = senderName.isEmpty ? "the student" : senderName
        switch self {
        case .template(let subject):
            var brief = """
                About this text: it is the message of \(from)'s email template. When the email is sent, each \
                placeholder is filled in for the recipient, so the same message goes to many recruiters at \
                different companies. Keep it right for all of them.
                """
            if let line = Self.subjectLine(subject) { brief += "\n" + line }
            return brief
        case .mail(let subject, let recipient):
            var to = recipient.name.isEmpty ? "a recruiter" : recipient.name
            if !recipient.position.isEmpty { to += ", \(recipient.position)" }
            if !recipient.company.isEmpty { to += " at \(recipient.company)" }
            var brief = """
                About this text: it is the message of one email from \(from) to \(to). It is sent from Gmail \
                exactly as written, so it must read as a finished email to that person.
                """
            if let line = Self.subjectLine(subject) { brief += "\n" + line }
            return brief
        case .companyLine(let company, let sector, let template):
            var brief = "About this text: it is \(from)'s personalised line for \(company)"
            if let sector, !sector.isEmpty { brief += " (\(sector))" }
            brief += ". It is put into every email \(from) sends to recruiters there, as one or two sentences in the middle of the email."
            if let template, let spot = Self.spot(in: template, company: company) {
                brief += " This is where it goes, marked [LINE]:\n\(spot)\nIt must read naturally in that place, without repeating what is around it."
            }
            return brief
        }
    }

    private static func subjectLine(_ subject: String) -> String? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "The email's subject line is: \(trimmed)"
    }

    /// The paragraph of `template` that holds the company line, with the line
    /// marked [LINE] and every other placeholder read out in words: shown
    /// braces, the model writes its own. With the line alone in its paragraph,
    /// the paragraphs either side come too. Nil when the template has no line.
    static func spot(in template: String, company: String) -> String? {
        let token = MailPlaceholder.companyPersonalised.token
        let paragraphs = template
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let index = paragraphs.firstIndex(where: { $0.contains(token) }) else { return nil }
        var range = index...index
        if paragraphs[index] == token {
            range = max(index - 1, 0)...min(index + 1, paragraphs.count - 1)
        }
        let words: [MailPlaceholder: String] = [
            .receiverName: "(their first name)",
            .receiverPosition: "(their job title)",
            .receiverCompany: company,
            .senderName: "(my name)",
            .senderCollege: "(my college)",
            .senderCompany: "(my employer)",
            .senderPosition: "(my job title)",
            .senderResume: "(my resume link)",
        ]
        var text = paragraphs[range].joined(separator: "\n\n").replacingOccurrences(of: token, with: "[LINE]")
        for placeholder in MailPlaceholder.allCases where placeholder != .companyPersonalised {
            text = text.replacingOccurrences(of: placeholder.token, with: words[placeholder] ?? "")
        }
        // Anything left in braces is a placeholder the app doesn't know.
        text = text.replacingOccurrences(of: "\\{[^{}]*\\}", with: "", options: .regularExpression)
        return text
    }

    // MARK: - For the user

    /// What the text is and who it's for, at the top of the sheet.
    var summary: (systemImage: String, kind: String, title: String) {
        switch self {
        case .template:
            return ("doc.text", "Template", "Goes to many recruiters")
        case .mail(_, let recipient):
            var to = recipient.name.isEmpty ? "One recruiter" : "To \(recipient.name)"
            if !recipient.company.isEmpty { to += " at \(recipient.company)" }
            return ("envelope", "Mail", to)
        case .companyLine(let company, let sector, _):
            var title = "For \(company)"
            if let sector, !sector.isEmpty { title += " · \(sector)" }
            return ("building.2", "Company line", title)
        }
    }

    /// The rest of what the model is told, as short lines under `summary`.
    func facts(hasProfile: Bool) -> [(systemImage: String, text: String)] {
        var facts: [(String, String)] = []
        switch self {
        case .template(let subject):
            if let subject = Self.shown(subject) { facts.append(("textformat", "Subject: \(subject)")) }
            facts.append(("curlybraces", "Keeps placeholders such as {Receiver-Name}"))
        case .mail(let subject, let recipient):
            if !recipient.position.isEmpty { facts.append(("person.text.rectangle", recipient.position)) }
            if let subject = Self.shown(subject) { facts.append(("textformat", "Subject: \(subject)")) }
            if hasProfile { facts.append(("person.crop.circle", "Your profile, when you ask for a detail of yours")) }
        case .companyLine(let company, _, let template):
            if let template, Self.spot(in: template, company: company) != nil {
                facts.append(("text.insert", "Where it sits in your template, to fit around it"))
            }
        }
        return facts.map { (systemImage: $0.0, text: $0.1) }
    }

    private static func shown(_ subject: String) -> String? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
