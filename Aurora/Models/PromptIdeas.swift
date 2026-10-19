import Foundation

/// Ready-made instructions for the writing-help sheet, written out in full so a
/// tap puts them in the box to send as they are or reword first. They're built
/// from what the app already knows (the company, its sector, the user's
/// profile, what the text already has) rather than being generic.
enum PromptIdeas {
    enum Kind {
        /// A template, which works in placeholders.
        case template
        /// One mail, already filled in, to someone at `company`.
        case mail(company: String?)
        /// The personalised line for a company.
        case line(company: String, sector: String?)
    }

    /// At most `limit` ideas for `text`. For a company line with nothing written
    /// yet they're notes on what the line should say; otherwise instructions.
    static func ideas(for kind: Kind, text: String, profile: Profile, limit: Int = 4) -> [String] {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let college = profile.isStudying ? profile.college.trimmingCharacters(in: .whitespaces) : ""
        let employer = profile.isWorking ? profile.company.trimmingCharacters(in: .whitespaces) : ""
        let position = profile.isWorking ? profile.position.trimmingCharacters(in: .whitespaces) : ""
        var ideas: [String] = []

        switch kind {
        case .template:
            func has(_ placeholder: MailPlaceholder) -> Bool { text.contains(placeholder.token) }
            if !has(.companyPersonalised) {
                ideas.append("Add \(MailPlaceholder.companyPersonalised.token) on its own line after the introduction")
            }
            if !has(.receiverName) { ideas.append("Start with a greeting that uses \(MailPlaceholder.receiverName.token)") }
            if !college.isEmpty, !has(.senderCollege) {
                ideas.append("Mention that I study at \(MailPlaceholder.senderCollege.token)")
            }
            if !has(.senderResume) { ideas.append("End by sharing my resume with \(MailPlaceholder.senderResume.token)") }
            ideas.append("Ask for a short call about open roles at \(MailPlaceholder.receiverCompany.token)")
            ideas.append("Make it sound more confident without boasting")

        case .mail(let company):
            if let company, !company.isEmpty {
                ideas.append("Add a sentence on why I want to work at \(company)")
                ideas.append("Ask for a short call about open roles at \(company)")
            }
            if !college.isEmpty, !text.localizedCaseInsensitiveContains(college) {
                ideas.append("Mention that I study at \(college)")
            }
            ideas.append("Make it sound more confident without boasting")
            ideas.append("End with a short thank-you")

        case .line(let company, let sector):
            let field = sector.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if hasText {
                ideas.append("Make it more specific to \(company)")
                if let field { ideas.append("Tie it to their work in \(field.lowercased())") }
                ideas.append("Make it sound more genuine and less formal")
                ideas.append("Keep it to one sentence")
            } else {
                ideas.append(field.map { "I admire \(company)'s work in \($0.lowercased()) and want to contribute to it" }
                             ?? "I admire what \(company) is building and want to contribute to it")
                if !employer.isEmpty {
                    ideas.append("My work " + (position.isEmpty ? "" : "as \(position) ") + "at \(employer) is close to what \(company) does")
                } else if !college.isEmpty {
                    ideas.append("What I'm learning at \(college) lines up with what \(company) does")
                }
                ideas.append("I've used \(company)'s product and would like to help build it")
            }
        }
        return Array(ideas.prefix(limit))
    }
}
