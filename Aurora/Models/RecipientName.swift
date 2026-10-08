import Foundation

/// Turns whatever is stored in a contact row into something safe to put after
/// "Hi " — or into nothing at all, when no name can be trusted.
///
/// Contact rows come from a shared, largely scraped catalog, so the `name` field
/// is unreliable in specific ways: it may be empty, ALL CAPS, carry an honorific
/// or credentials ("Dr. Anjali Kumari", "Rohit Sharma, PMP"), be filed surname
/// first ("KUMARI, Anjali"), or just be a copy of the email address. Taking the
/// first whitespace-separated word — what this used to do — turns those into
/// "Hi ,", "Hi ANJALI,", "Hi Dr.," and "Hi anjali.kumari@acme.com,", each of
/// which is worse than not using the person's name at all.
///
/// So a guess is only made when it's a confident one — from an address, that
/// call is `NameClassifier`'s. Anything less gives ``fallback`` — empty — and
/// the template closes up around it: "Hi {Receiver-Name}," is sent as "Hi,"
/// (see `MailText`). Greeting a stranger by the wrong name costs more than
/// greeting them by none.
enum RecipientName {
    /// What to greet by when no name can be trusted: nothing.
    static let fallback = ""

    /// Reads names off addresses. The bundled model; tests hand in their own.
    static var classifier: NameClassifier? = NameClassifier.shared

    /// Honorifics and credentials that precede a given name. Matched
    /// case-insensitively, with or without a trailing period.
    private static let honorifics: Set<String> = [
        "mr", "mrs", "ms", "miss", "mx", "dr", "prof", "professor", "sir",
        "madam", "madame", "shri", "smt", "sri", "er", "ca", "capt", "rev", "hon"
    ]

    /// Words that belong to a function rather than a person. A mail to
    /// `careers@` opening with "Hi Careers," is worse than "Hi,". The same list
    /// as `ROLE` in `scripts/company_verification/verify_names.py`.
    private static let roleWords: Set<String> = [
        "hr", "info", "jobs", "job", "careers", "career", "recruiting", "recruitment", "recruiter",
        "recruiters", "talent", "hiring", "contact", "hello", "team", "admin", "support", "apply",
        "applications", "resume", "resumes", "cv", "office", "people", "staffing", "internships",
        "internship", "campus", "noreply", "no-reply", "ta", "talentacquisition", "corporatehr", "hrd",
        "hrteam", "placement", "placements", "operations", "dl", "mailer", "enquiry", "enquiries",
        "sales", "backend", "frontend", "engineering", "tech", "india", "global", "services",
        "connect", "reachouts", "outreach", "partnerships", "partner", "business", "marketing", "ops"
    ]

    /// Filler that rides along with a name in a mailbox ("naren.official",
    /// "im_naren") without being one.
    private static let fillerWords: Set<String> = [
        "here", "official", "work", "mail", "me", "the", "real", "its", "im", "iam", "mr", "ms", "dr"
    ]

    /// A given name to greet the recipient by, or ``fallback`` when there's no
    /// name it can be sure of.
    ///
    /// `email` is only consulted when `name` yields nothing usable, or when the
    /// name is just the mailbox copied over ("Akushwah" for `akushwah@`) and so
    /// knows no more than the address does.
    static func greeting(name: String, email: String) -> String {
        let mailbox = email.prefix { $0 != "@" }
        if bareLetters(name) != bareLetters(String(mailbox)),
           let fromName = personalName(in: name) {
            return fromName
        }
        if let fromEmail = nameFromEmail(email) { return fromEmail }
        return fallback
    }

    // MARK: - From the name field

    private static func personalName(in raw: String) -> String? {
        var text = raw.sanitizedLineSeparators.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Some rows store the email in the name column; treat that as an email.
        if text.contains("@") { return nil }

        // Drop pronouns and notes in brackets: "Anjali Kumari (she/her)".
        if text.contains("(") || text.contains("[") {
            text = text.replacingOccurrences(of: "\\([^)]*\\)|\\[[^]]*\\]", with: " ",
                                             options: .regularExpression)
        }

        // "KUMARI, Anjali" files the surname first, so the given name follows the
        // comma. Credentials do too ("Rohit Sharma, PMP"), but those trail a
        // complete name, so only prefer the tail when the head is a single word.
        let commaParts = text.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if commaParts.count == 2,
           !commaParts[1].isEmpty,
           commaParts[0].split(separator: " ").count == 1 {
            text = commaParts[1]
        } else {
            text = commaParts[0]
        }

        // First word that isn't an honorific and is long enough to be a name.
        // Initials ("A. Kumari") fail the length test and fall through to the
        // surname, which greets better than "Hi A,".
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let cleaned = letters(in: String(word))
            guard !cleaned.isEmpty else { continue }
            if honorifics.contains(cleaned.lowercased()) { continue }
            guard cleaned.count >= 2 else { continue }
            return recased(cleaned)
        }
        return nil
    }

    // MARK: - From the email address

    /// A given name read off the address, when `NameClassifier` is sure of one.
    ///
    /// An address alone doesn't say where one name ends and the next begins:
    /// `akushwah` is A Kushwah, `nehamathur` is Neha Mathur, `rahul` is Rahul.
    /// The classifier weighs those readings against lists of given names,
    /// surnames and words, and gives a name only when the readings that greet by
    /// it far outweigh the rest; `akushwah`, `pm.singh` and `sharma` give none.
    /// Role and filler words and the company's own name are dropped first, and
    /// letters wrapped around digits (`talk2saravanan`) are leetspeak, not a name.
    /// `verify_names.py` can still store a `greeting_name` from what the whole
    /// catalog teaches it, which outranks this.
    private static func nameFromEmail(_ email: String) -> String? {
        let parts = email.lowercased().trimmingCharacters(in: .whitespaces)
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let local = String(parts[0].prefix { $0 != "+" })
        guard !local.isEmpty, !roleWords.contains(local) else { return nil }

        // Letters on both sides of a digit are leetspeak, not a separator.
        if local.range(of: "[a-z][0-9]+[a-z]", options: .regularExpression) != nil { return nil }

        // The company's own name ("oracle.india@oracle.com") is no one's name.
        let domainLabels = Set(parts.dropFirst().flatMap { $0.split(separator: ".").map(String.init) })
        let words = local.split(whereSeparator: { !("a"..."z").contains($0) })
            .map(String.init)
            .filter { !roleWords.contains($0) && !fillerWords.contains($0) && !domainLabels.contains($0) }
        guard !words.isEmpty else { return nil }

        if let classifier {
            return classifier.greeting(parts: words).name
        }
        // No model in the bundle: only a mailbox that spells out a given name
        // and a surname separately (`anjali.kumari`) is trusted.
        guard words.count >= 2, words[0].count >= 3 else { return nil }
        return recased(words[0])
    }

    // MARK: - Helpers

    /// Strip anything that isn't a letter or an intra-name mark, so stray
    /// punctuation and emoji don't survive into the greeting. Apostrophes and
    /// hyphens are kept: "O'Brien" and "Anne-Marie" are names.
    private static func letters(in word: String) -> String {
        String(word.filter { $0.isLetter || $0 == "'" || $0 == "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    /// Just the letters, lowercased: "Talk2saravanan" and `talk2saravanan` match.
    private static func bareLetters(_ text: String) -> String {
        String(text.lowercased().filter(\.isLetter))
    }

    /// Fix case only when the source was uniformly cased, which is the signature
    /// of machine-entered data. A name that already mixes cases was written by a
    /// human who knew how it should look — "McDonald", "O'Brien", "deSouza" — and
    /// capitalizing it would make it worse, not better.
    private static func recased(_ word: String) -> String {
        let isUniform = word.lowercased() == word || word.uppercased() == word
        guard isUniform else { return word }
        return word.localizedCapitalized
    }
}
