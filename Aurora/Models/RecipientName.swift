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

    // MARK: - Learning from the catalog

    /// What each contact last taught, by contact: compared as a whole, so a
    /// reload that changes no one's name (or only the order they arrive in)
    /// doesn't make the classifier learn the same catalog again.
    private static var lastLearned: [String: [String]] = [:]
    /// Name words already worked out, by everything they're worked out from, so
    /// each catalog page reads only the rows it hasn't seen.
    private static var wordsCache: [String: [String]] = [:]
    private static let noWords: [String] = []

    /// Teach the classifier the names in the catalog loaded so far, so a name
    /// the public lists lack ("Arijit Sen" on one contact) can greet another
    /// contact whose address is all there is (`arijit@`). Rows whose name is
    /// their mailbox copied over, holds an address, or names a role teach
    /// nothing; `NameClassifier.learn` decides what the rest teach.
    static func learnNames(from contacts: [Contact], mailboxEntry: (String) -> String? = { _ in nil }) {
        guard let classifier else { return }
        if wordsCache.count > 50_000 { wordsCache.removeAll(keepingCapacity: true) }
        var people: [String: [String]] = [:]
        for contact in contacts {
            let id = contact.id.isEmpty ? contact.email : contact.id
            guard people[id] == nil else { continue }
            let entry = mailboxEntry(contact.email)
            let key = [contact.name, contact.email, contact.replyFrom ?? "", entry ?? ""].joined(separator: "\u{1F}")
            let words = wordsCache[key] ?? taught(by: contact, entry: entry)
            wordsCache[key] = words
            if !words.isEmpty { people[id] = words }
        }
        guard people != lastLearned else { return }
        lastLearned = people
        classifier.learn(people: Array(people.values))
    }

    /// What one contact teaches: its name field, or failing that the name it
    /// signed a reply with or its address carries in this account's mail.
    private static func taught(by contact: Contact, entry: String?) -> [String] {
        if let words = nameWords(in: contact.name, email: contact.email) { return words }
        for header in [contact.replyFrom, entry].compactMap({ $0 }) where signedName(in: header, for: contact.email) != nil {
            guard let open = header.lastIndex(of: "<"),
                  let words = nameWords(in: header[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'")),
                                        email: contact.email) else { continue }
            return words
        }
        return noWords
    }

    /// A name field as lowercase a-z words, given name first where a comma
    /// says the surname leads ("KUMARI, Anjali"), or nil if it can't teach.
    private static func nameWords(in raw: String, email: String) -> [String]? {
        var text = raw.sanitizedLineSeparators.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("@"), !isMailboxCopy(text, of: email) else { return nil }
        if text.contains("(") || text.contains("[") {
            text = text.replacingOccurrences(of: "\\([^)]*\\)|\\[[^]]*\\]", with: " ",
                                             options: .regularExpression)
        }
        let commaParts = text.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if commaParts.count == 2, !commaParts[1].isEmpty, commaParts[0].split(separator: " ").count == 1 {
            text = commaParts[1] + " " + commaParts[0]
        } else {
            text = commaParts[0]
        }
        var words: [String] = []
        for raw in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "." }) {
            let word = String(raw.filter { $0 != "'" })
            guard !word.isEmpty else { continue }
            // A word with anything else in it (digits, another script) is no name to learn.
            guard word.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
            if honorifics.contains(word) { continue }
            if roleWords.contains(word) { return nil }
            words.append(word)
        }
        return words.count >= 2 ? words : nil
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
