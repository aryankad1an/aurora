import Foundation

/// Turns whatever is stored in a contact row into something safe to put after
/// "Hi ".
///
/// Contact rows come from a shared, largely scraped catalog, so the `name` field
/// is unreliable in specific ways: it may be empty, ALL CAPS, carry an honorific
/// or credentials ("Dr. Anjali Kumari", "Rohit Sharma, PMP"), be filed surname
/// first ("KUMARI, Anjali"), or just be a copy of the email address. Taking the
/// first whitespace-separated word — what this used to do — turns those into
/// "Hi ,", "Hi ANJALI,", "Hi Dr.," and "Hi anjali.kumari@acme.com,", each of
/// which is worse than not using the person's name at all.
enum RecipientName {
    /// What to say when no usable name can be recovered. "Hi there," reads as a
    /// deliberate choice; "Hi ," reads as a broken mail merge.
    static let fallback = "there"

    /// Honorifics and credentials that precede a given name. Matched
    /// case-insensitively, with or without a trailing period.
    private static let honorifics: Set<String> = [
        "mr", "mrs", "ms", "miss", "mx", "dr", "prof", "professor", "sir",
        "madam", "madame", "shri", "smt", "sri", "er", "ca", "capt", "rev", "hon"
    ]

    /// Mailbox names that belong to a function rather than a person. A mail to
    /// `careers@` opening with "Hi Careers," is worse than "Hi there,".
    private static let roleMailboxes: Set<String> = [
        "hr", "info", "jobs", "careers", "career", "recruiting", "recruitment",
        "recruiter", "talent", "hiring", "contact", "hello", "team", "admin",
        "support", "apply", "applications", "resume", "resumes", "cv", "office",
        "people", "staffing", "internships", "campus", "noreply", "no-reply"
    ]

    /// A given name to greet the recipient by, or ``fallback``.
    ///
    /// `email` is only consulted when `name` yields nothing usable, and only when
    /// its mailbox looks like a person's rather than a department's.
    static func greeting(name: String, email: String) -> String {
        if let fromName = personalName(in: name) { return fromName }
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

    private static func nameFromEmail(_ email: String) -> String? {
        let mailbox = email.split(separator: "@").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let mailbox, !mailbox.isEmpty, !roleMailboxes.contains(mailbox) else { return nil }

        // "anjali.kumari" / "anjali_kumari" / "anjali-kumari87" → "Anjali".
        for part in mailbox.split(whereSeparator: { ".-_+0123456789".contains($0) }) {
            let cleaned = letters(in: String(part))
            guard cleaned.count >= 2, !roleMailboxes.contains(cleaned) else { continue }
            return recased(cleaned)
        }
        return nil
    }

    // MARK: - Helpers

    /// Strip anything that isn't a letter or an intra-name mark, so stray
    /// punctuation and emoji don't survive into the greeting. Apostrophes and
    /// hyphens are kept: "O'Brien" and "Anne-Marie" are names.
    private static func letters(in word: String) -> String {
        String(word.filter { $0.isLetter || $0 == "'" || $0 == "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
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
