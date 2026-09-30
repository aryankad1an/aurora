import Foundation

/// A mail that came back undelivered: to whom, when, and what the notice said.
struct Bounce: Codable, Identifiable {
    var id: Contact.ID { contactID }
    let contactID: Contact.ID
    /// The address that bounced, lowercased. A contact whose address has since
    /// been corrected no longer counts as bounced.
    let address: String
    /// When the failure notice arrived.
    let at: Date
    /// The notice's opening text, which says why.
    let snippet: String?
    /// The enhanced status code from the notice's report (`5.1.1`), when it had
    /// one. Nil for bounces found before reports were read.
    let status: String?
    /// The receiving server's own explanation, from the report.
    let diagnostic: String?

    var reason: BounceReason {
        BounceParsing.reason(status: status, text: [diagnostic, snippet].compactMap { $0 }.joined(separator: " "))
    }

    /// What the receiving server said: its own words from the report where
    /// there are some, the notice's opening text otherwise.
    var serverMessage: String? { diagnostic ?? snippet }
}

/// What `ReplySync` keeps on disk about bounces, per account.
struct BounceLog: Codable {
    var bounces: [Bounce] = []
    var seenMessageIDs: [String] = []
    var dismissed: [Contact.ID: Date] = [:]
}

/// A bounce worth showing: the contact still exists, is still marked valid,
/// still has the address that bounced, and hasn't answered since.
struct BouncedContact: Identifiable {
    let bounce: Bounce
    let contact: Contact
    let company: String
    var id: Contact.ID { contact.id }
}

extension JobStore {
    /// The bounces still to be dealt with, newest first. Looked up through the
    /// send history, which holds every mailed contact with their current row,
    /// so a contact at a company not on screen is still found.
    func bouncedContacts(from sync: ReplySync) -> [BouncedContact] {
        guard !sync.bounces.isEmpty else { return [] }
        var byID: [Contact.ID: (Contact, String)] = [:]
        for entry in activity where byID[entry.contact.id] == nil {
            byID[entry.contact.id] = (entry.contact, entry.company)
        }
        return sync.bounces.values.compactMap { bounce -> BouncedContact? in
            guard let (contact, company) = byID[bounce.contactID]
                    ?? contact(id: bounce.contactID).map({ ($0, "") }) else { return nil }
            guard contact.isValid,
                  contact.email.lowercased() == bounce.address,
                  !(contact.repliedAt.map { $0 > bounce.at } ?? false) else { return nil }
            return BouncedContact(bounce: bounce, contact: contact, company: company)
        }
        .sorted { $0.bounce.at > $1.bounce.at }
    }

    /// Mark bounced contacts invalid — shared, for every user — and clear their
    /// bounces once the write lands.
    func markBouncedInvalid(_ ids: [Contact.ID], sync: ReplySync) async {
        guard await setValidity(ids, isValid: false) else { return }
        sync.resolveBounces(ids)
    }
}
