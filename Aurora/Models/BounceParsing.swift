import Foundation

/// Reading a delivery-failure notice: whether a message is one, whether it's
/// final or only a delay, which addresses it's about, and why they failed.
///
/// Kept free of the rest of the app so it can be tested on its own:
///
///     swiftc Aurora/Models/BounceParsing.swift Tests/BounceParsingTests.swift -o /tmp/bt && /tmp/bt
nonisolated enum BounceParsing {

    /// Mail servers send failure notices as the mailer daemon or the postmaster.
    static func isBounceSender(_ from: String?) -> Bool {
        let sender = (from ?? "").lowercased()
        return sender.contains("mailer-daemon") || sender.contains("postmaster")
    }

    /// A "still trying" notice rather than a failure. Gmail sends one when a
    /// server is slow to accept a mail, then keeps retrying for days, and most
    /// of those mails are delivered in the end. Treating a delay as a bounce
    /// would rule out live addresses.
    static func isDelay(subject: String?, snippet: String?) -> Bool {
        let subject = (subject ?? "").lowercased()
        if subject.contains("delay") { return true }
        let text = (snippet ?? "").lowercased()
        return text.contains("will retry") || text.contains("temporary problem")
            || text.contains("has been delayed") || text.contains("not yet been delivered")
            || text.contains("hasn't been delivered yet")
    }

    /// The addresses a notice says it couldn't deliver to, lowercased. Gmail
    /// names them in an `X-Failed-Recipients` header; notices without one name
    /// them in the text ("wasn't delivered to jane@acme.com because…").
    static func failedAddresses(header: String?, snippet: String?) -> [String] {
        if let header, !header.trimmingCharacters(in: .whitespaces).isEmpty {
            let listed = header.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased() }
                .filter { $0.contains("@") }
            if !listed.isEmpty { return listed }
        }
        guard let snippet else { return [] }
        var found: [String] = []
        for match in snippet.matches(of: #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#) {
            let address = String(match.output).lowercased()
            guard !isBounceSender(address), !found.contains(address) else { continue }
            found.append(address)
        }
        return found
    }

    static func reason(in snippet: String?) -> BounceReason {
        let text = (snippet ?? "").lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { text.contains($0) } }
        // Before "address not found": Gmail's notice for a dead domain is headed
        // "Address not found" too, and only its text says it's the domain.
        if has("the domain", "domain not found", "5.1.2", "dns") && has("couldn't be found", "not found", "5.1.2", "dns") {
            return .domainNotFound
        }
        if has("address not found", "couldn't be found", "does not exist", "doesn't exist", "user unknown",
               "no such user", "5.1.1", "unknown recipient", "invalid recipient", "mailbox unavailable",
               "recipient not found", "address rejected") {
            return .addressNotFound
        }
        if has("mailbox full", "mailbox is full", "over quota", "quota exceeded", "5.2.2", "out of storage", "inbox is full") {
            return .mailboxFull
        }
        if has("blocked", "rejected", "policy", "spam", "5.7.", "not allowed", "denied") {
            return .rejected
        }
        return .other
    }
}

/// Why a mail came back, as the notice put it.
nonisolated enum BounceReason: Equatable {
    case addressNotFound, domainNotFound, mailboxFull, rejected, other

    var label: String {
        switch self {
        case .addressNotFound: "Address not found"
        case .domainNotFound: "Domain doesn't exist"
        case .mailboxFull: "Mailbox full"
        case .rejected: "Rejected by their server"
        case .other: "Couldn't be delivered"
        }
    }

    var systemImage: String {
        switch self {
        case .addressNotFound: "person.crop.circle.badge.xmark"
        case .domainNotFound: "globe.badge.chevron.backward"
        case .mailboxFull: "tray.full"
        case .rejected: "hand.raised"
        case .other: "exclamationmark.triangle"
        }
    }
}
