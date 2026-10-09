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
/// So a name is only used when it's plainly there: a name field written as a
/// name, a signed reply, a header in the account's own mail, or an address
/// that spells the given name out as its own part (`anjali.kumari`). Nothing
/// is guessed from a glued mailbox (`akushwah`, `nehamathur`). Anything less
/// gives ``fallback`` — empty — and the template closes up around it:
/// "Hi {Receiver-Name}," is sent as "Hi," (see `MailText`). Greeting a stranger by the wrong name costs more than
/// greeting them by none.
enum RecipientName {
    /// What to greet by when no name can be trusted: nothing.
    static let fallback = ""

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
    /// In order: the `name` field; the name the person signed their own reply
    /// with (`replyFrom`, the `From:` of a reply from this same address); the
    /// name their address carries elsewhere in this account's mail
    /// (`mailboxEntry`, from `MailboxNames`); and the address itself. Each later
    /// one is consulted only when the ones before yield nothing usable — a name
    /// that is just the mailbox copied over ("Akushwah" for `akushwah@`) knows
    /// no more than the address does.
    static func greeting(name: String, email: String, replyFrom: String? = nil,
                         mailboxEntry: String? = nil) -> String {
        if !isMailboxCopy(name, of: email), let fromName = personalName(in: name) {
            return fromName
        }
        if let fromReply = replyFrom.flatMap({ signedName(in: $0, for: email) }) { return fromReply }
        if let fromMail = mailboxEntry.flatMap({ signedName(in: $0, for: email) }) { return fromMail }
        if let fromEmail = nameFromEmail(email) { return fromEmail }
        return fallback
    }

    /// Whether a contact has nothing better than its address to be greeted by —
    /// no greeting of its own, no usable name field, no signed reply — and so is
    /// worth looking up in the account's mail.
    static func needsLookup(name: String, email: String, greetingName: String?, replyFrom: String? = nil) -> Bool {
        guard (greetingName ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isMailboxCopy(name, of: email), personalName(in: name) != nil { return false }
        return replyFrom.flatMap { signedName(in: $0, for: email) } == nil
    }

    /// A name that is only the mailbox copied over: one word with the same
    /// letters ("Akushwah" or "Talk2saravanan" for `akushwah@`, `talk2saravanan@`).
    /// It knows no more than the address does. A spaced name that matches a
    /// `first.last` address ("Arijit Sen" for `arijit.sen@`) is a real name: it
    /// says where one part ends and the next begins, and which comes first.
    static func isMailboxCopy(_ name: String, of email: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace) else { return false }
        return bareLetters(text) == bareLetters(String(email.prefix { $0 != "@" }))
    }

    /// Whether a header entry ("Aryan Kadian <kdaryan@acme.com>") names the
    /// person at `email`, by the same rules as a signed reply.
    static func isPersonEntry(_ entry: String, for email: String) -> Bool {
        signedName(in: entry, for: email) != nil
    }

    // MARK: - From their own reply

    /// The given name in a `From:` header ("Anjali Kumari <anjali@acme.com>"),
    /// when it came from `email` itself and names a person: the name someone
    /// signs their own mail with is the best name there is for them. A display
    /// name that names a role ("Acme Recruiting") or only repeats the mailbox
    /// gives nil, as does a reply sent from some other address.
    private static func signedName(in header: String, for email: String) -> String? {
        guard let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">"), open < close else {
            return nil
        }
        let address = header[header.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        guard address.caseInsensitiveCompare(email.trimmingCharacters(in: .whitespaces)) == .orderedSame else {
            return nil
        }
        let display = header[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let words = display.lowercased().split(whereSeparator: { !$0.isLetter })
        guard !display.isEmpty, !words.contains(where: { roleWords.contains(String($0)) }),
              !isMailboxCopy(display, of: email) else { return nil }
        return personalName(in: display)
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

        // First word that isn't an honorific or initials. Initials ("A. Kumari",
        // "NS Acharya", "Ak Sinha") fall through to the surname, which greets
        // better than "Hi A," or "Hi Ak,".
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let cleaned = letters(in: String(word))
            guard !cleaned.isEmpty else { continue }
            if honorifics.contains(cleaned.lowercased()) { continue }
            if isInitials(cleaned) { continue }
            return recased(cleaned)
        }
        return nil
    }

    // MARK: - From the email address

    /// The given name an address spells out as its own part, or nil.
    ///
    /// Only a mailbox that separates a given name from the rest is read:
    /// `anjali.kumari`, `anjali_kumari`, `rahul.k` give Anjali, Anjali, Rahul.
    /// A glued mailbox doesn't say where one name ends and the next begins —
    /// `akushwah` is A Kushwah, `nehamathur` Neha Mathur, `sanhussain` who knows —
    /// so it gives nil rather than a guess, as do a lone word (`rahul`, which may
    /// as well be a surname), initials first (`pm.singh`, `r.saravanan`) and
    /// letters wrapped around digits (`talk2saravanan`). Role and filler words
    /// and the company's own name are dropped first.
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
        guard words.count >= 2, let given = words.first, given.count >= 3,
              given.contains(where: { "aeiouy".contains($0) }) else { return nil }
        return recased(given)
    }

    // MARK: - Helpers

    /// Strip anything that isn't a letter or an intra-name mark, so stray
    /// punctuation and emoji don't survive into the greeting. Apostrophes and
    /// hyphens are kept: "O'Brien" and "Anne-Marie" are names.
    private static func letters(in word: String) -> String {
        String(word.filter { $0.isLetter || $0 == "'" || $0 == "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    /// Two-letter given names. Any other word of one or two letters ("A",
    /// "NS", "Pm", "Ak") is initials. The same list as `SHORT_NAMES` in
    /// `scripts/company_verification/verify_names.py`.
    private static let shortNames: Set<String> = [
        "om", "qi", "li", "yu", "bo", "jo", "al", "ed", "ai", "su", "ji", "yi", "xu", "wu", "lu", "ye", "ko"
    ]

    /// Initials rather than a name.
    private static func isInitials(_ word: String) -> Bool {
        word.count <= 2 && !shortNames.contains(word.lowercased())
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
