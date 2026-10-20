import Foundation

/// A fresher role as the company page shows it. The roles come from a scraped
/// ledger, and many are a post's labelled fields run together ("Company Name:
/// AgodaRole: Software Developer (Contract)"), with batches, degrees and "Apply
/// Now" glued on. This keeps the role's name and leaves the stored text alone.
nonisolated enum RoleTitle {
    /// The roles worth showing, cleaned, in their order and without repeats.
    static func cleaned(_ roles: [String]) -> [String] {
        var seen = Set<String>()
        return roles.compactMap(clean).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The role's name alone, or nil when nothing is left, as with a post that
    /// names only the company.
    static func clean(_ raw: String) -> String? {
        // Compatibility mapping turns styled letters (𝐑𝐨𝐥𝐞) and no-break spaces
        // into plain ones, so the labels below can be found.
        var text = replacing(whitespace, in: raw.precomposedStringWithCompatibilityMapping, with: " ")

        // Labelled fields: the role's value if there is one, else whatever came
        // before the first label. Labels are often glued to the previous value.
        let labels = label.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if let first = labels.first {
            let ns = text as NSString
            func value(at index: Int) -> String {
                let start = labels[index].range.upperBound
                let end = index + 1 < labels.count ? labels[index + 1].range.location : ns.length
                return ns.substring(with: NSRange(location: start, length: end - start))
            }
            if let role = labels.indices.first(where: { roleLabels.contains(name(of: labels[$0], in: ns)) }) {
                text = value(at: role)
            } else {
                text = ns.substring(to: first.range.location)
            }
        }

        // A role glued to what followed it ("Data EngineerApply Now", "Trainee
        // ComputerScience/…"): keep up to the end of the role's noun, or up to
        // the degrees or note run into it ("(0-2 Years)BE/BTech", "1Reposted").
        if let glued = gluedNoun.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            text = (text as NSString).substring(to: glued.range.upperBound)
        }
        if let glued = gluedTail.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            text = (text as NSString).substring(to: glued.range.location)
        }

        for (regex, replacement) in tidying {
            text = replacing(regex, in: text, with: replacement)
        }
        // A value the ledger cut off mid-parenthesis: "Software Engineer ( Backend,".
        if text.filter({ $0 == "(" }).count > text.filter({ $0 == ")" }).count,
           let open = text.lastIndex(of: "(") {
            text = String(text[..<open])
        }
        text = replacing(trailing, in: text, with: "")

        if !text.isEmpty, text == text.lowercased() { text = titleCased(text) }
        return text.count < 2 ? nil : text
    }

    private static let roleLabels: Set<String> = ["role", "roles", "position", "job title"]

    /// "Company Name:", "Role :" or "Batch eligible:" anywhere, even glued to the
    /// word before; a few take a dash instead ("Role - ", "Exp - ").
    private static let label = try! NSRegularExpression(
        pattern: #"(?:(company name|company|job title|position|roles?|batch eligible|batches|batch|qualifications|education|eligibility|experience required|duration|location|for graduates|skills|yoe|ctc|exp)\s*:\s*|(roles?|exp|location|job level)\s+[-–]\s+)"#,
        options: .caseInsensitive)

    private static func name(of match: NSTextCheckingResult, in text: NSString) -> String {
        let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return text.substring(with: group).lowercased()
    }

    /// A role noun run straight into a capitalised word. Case-sensitive, so
    /// "DevOps" and "FullStack" stay whole.
    private static let gluedNoun = try! NSRegularExpression(
        pattern: #"(Engineers?|Developers?|Trainee|Interns?|Analysts?|Testers?|Designers?|Scientists?|Programmers?|Freshers?|Grads|Remote|Test|Years?|Experience)(?=[A-Z])"#)

    /// Degrees, notes and job boards run straight into the text before them.
    private static let gluedTail = try! NSRegularExpression(
        pattern: #"(?<=[a-z0-9)])(BE/|B\.?Tech|BCA\b|BSC\b|Degree\b|Expected\b|Greetings\b|Internal\b|Reposted\b|Freshers?\b|Apply Now|JobsNet|Jobsnet)"#)

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    private static let trailing = try! NSRegularExpression(pattern: #"[\s\-–|:,!*]+$"#)

    /// What surrounds the role: hiring calls, batches, experience and pay ranges,
    /// job boards. In order, case-insensitive. Compiled once: `clean` runs for
    /// every role a company page draws.
    private static let tidying: [(NSRegularExpression, String)] = [
        (#"(?i)\s*apply now$"#, ""),
        (#"(?i)\s*for\s+(graduates\s*:?\s*)?\d{4}.*$"#, ""),
        (#"(?i)\s*\d{4}(\s*[/,&]\s*\d{2,4})*\s+(batch|passout).*$"#, ""),
        (#"\s*\(\d{4}\)"#, ""),
        (#"(?i)\s*\(fresher(?:'|’)?s?\)"#, ""),
        (#"(?i)\s*[-–|]?\s*\(?\d+\s*([-–]|to)\s*\d+\s*(year(?:'|’)s|years?|yrs?)\)?(\s*(of\s+)?experience\)?)?"#, ""),
        (#"(?i)\s*\d+\+.*experience.*$"#, ""),
        (#"(?i)\s*[|(\-–]?\s*₹?\d[\d.]*\s*l?\s*[-–]\s*₹?\d[\d.]*\s*(lpa|l)\b.*$"#, ""),
        (#"(?i)\s*[-–|]\s*jobsnet.*$"#, ""),
        (#"(?i)\s*recently\b.*$"#, ""),
        (#"\s*[-–]\s*\d{4}$"#, ""),
        (#"^[\s!–\-|•*]+"#, ""),
        (#"^\d[\d-]*\s*:\s*"#, ""),
        (#"(?i)^(we'?re\s+)?hiring\s+"#, ""),
        (#"(?i)^for\s+"#, ""),
        (#"(?i)^(the\s+)?role\s+of\s+"#, ""),
        // "Freshers As Data Engineer", "Fresher Software Engineer"; not "Freshers &
        // Experienced …".
        (#"(?i)^(freshers?|new grads)\s*([-–:|]\s*|as\s+|for\s+|(?-i:(?=[A-Z])))"#, ""),
        (#"(?i)([\s.]*[-–|,/]?\s*\b(fresher(?:'|’)?s?( only)?|new( college)? grads|early careers|any batch)[\s/.]*)+$"#, ""),
        (#"(?i)\s+(batch( eligible)?|role)\.?$"#, ""),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let acronyms: Set<String> = ["sde", "sdet", "ai", "ml", "qa", "ui", "ux", "aws", "it", "pm", "hr"]

    /// "junior software engineer" → "Junior Software Engineer", "sde 1" → "SDE 1".
    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            acronyms.contains(String(word)) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }
}
