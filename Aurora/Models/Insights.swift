import Foundation

/// Everything Quick Actions and Home's summary card show, computed once per
/// load rather than re-derived inside a view body.
///
/// It's built from the Activity feed (one entry per *send*) instead of from the
/// company catalog, for the same reason Activity is: outreach history has to
/// survive a company being untracked or a contact being marked invalid. The
/// catalog is consulted only to resolve a company name back to something
/// navigable.
struct Insights {

    /// One company's outreach record. `id` is the company name, which is what the
    /// send history actually preserves — `companyID` is nil when the company has
    /// since left the catalog.
    struct CompanyStat: Identifiable {
        let name: String
        let companyID: String?
        /// Every send to this company, newest first.
        let entries: [ActivityEntry]
        let lastSentAt: Date?
        let lastReplyAt: Date?
        let sent: Int
        let replies: Int
        let people: Int

        var id: String { name }
        var isSilent: Bool { replies == 0 }

        init(name: String, companyID: String?, entries: [ActivityEntry]) {
            self.name = name
            self.companyID = companyID
            self.entries = entries
            self.lastSentAt = entries.compactMap(\.date).max()
            self.lastReplyAt = entries.compactMap(\.contact.repliedAt).max()
            self.sent = entries.count
            self.replies = entries.count { $0.contact.hasReplied }
            self.people = Set(entries.map(\.contact.id)).count
        }
    }

    /// One unanswered mail, kept per *person* rather than per send: the last
    /// thing you wrote them and how long it has been quiet since. The Waiting
    /// lane of Quick Actions lists these, filters them by age, and mails a
    /// follow-up to whichever ones are ticked — so a contact mailed twice is
    /// one row and one follow-up, not two.
    struct WaitingMail: Identifiable {
        let contact: Contact
        let company: String
        /// nil once the company has left the catalog — the send history keeps the
        /// name, but there is nothing left to navigate to.
        let companyID: String?
        let sentAt: Date?
        /// Whole days of silence. What the lane sorts and filters on.
        let days: Int

        var id: Contact.ID { contact.id }

        /// A follow-up can only go to a live address. Bounced and ruled-out
        /// contacts still appear — the silence is real and worth seeing — but
        /// they are never ticked and never sent.
        var isMailable: Bool { contact.isMailable }
    }

    var companies: [CompanyStat] = []

    /// Companies that have heard from you and said nothing back, longest silence
    /// first — the running order of the follow-up queue.
    var waitingOn: [CompanyStat] = []
    /// Companies where somebody replied, most recent first.
    var responded: [CompanyStat] = []

    var totalSent = 0
    var totalReplies = 0
    /// Distinct people who wrote back — replies counts sends, and the same person
    /// answering twice isn't two leads.
    var repliedPeople = 0
    /// Sends still unanswered, newest first.
    var unanswered: [ActivityEntry] = []
    /// Everyone who wrote back, most recent reply first.
    var replies: [ActivityEntry] = []
    /// The unanswered sends collapsed to one row per person, longest silence
    /// first — the follow-up queue, ready to be filtered by age.
    var waitingMails: [WaitingMail] = []

    var replyRate: Double {
        totalSent == 0 ? 0 : Double(totalReplies) / Double(totalSent)
    }

    /// Typical wait before an answer arrives, in days — the median rather than the
    /// mean, so one contact who answered six weeks later doesn't move it.
    var medianResponseDays: Int?

    /// The longest anyone has been left hanging, in days. Read off the person
    /// queue rather than the company one, so it means the same thing Quick
    /// Actions' first row does — a company with one reply and three silences
    /// isn't "answered" as far as those three people are concerned.
    var longestSilenceDays: Int? { waitingMails.first?.days }

    // MARK: - Building

    static func make(activity: [ActivityEntry], catalog: [Job]) -> Insights {
        var insights = Insights()
        insights.totalSent = activity.count
        insights.replies = activity
            .filter(\.contact.hasReplied)
            .sorted { ($0.contact.repliedAt ?? .distantPast) > ($1.contact.repliedAt ?? .distantPast) }
        insights.totalReplies = insights.replies.count
        insights.repliedPeople = Set(insights.replies.map(\.contact.id)).count
        insights.unanswered = activity.filter { !$0.contact.hasReplied }

        let idByName = Dictionary(catalog.map { ($0.company, $0.id) }, uniquingKeysWith: { first, _ in first })

        // Preserve the feed's newest-first order within each company, and order
        // the companies themselves by however the caller sorts them later.
        var order: [String] = []
        var byCompany: [String: [ActivityEntry]] = [:]
        for entry in activity where !entry.company.isEmpty {
            if byCompany[entry.company] == nil { order.append(entry.company) }
            byCompany[entry.company, default: []].append(entry)
        }

        insights.companies = order.map { name in
            CompanyStat(name: name, companyID: idByName[name], entries: byCompany[name] ?? [])
        }

        // The lanes are derived once here rather than on each access: a view body
        // reads several of them, and SwiftUI re-reads them on every pass.
        insights.waitingOn = insights.companies
            .filter(\.isSilent)
            .sorted { ($0.lastSentAt ?? .distantPast) < ($1.lastSentAt ?? .distantPast) }
        insights.responded = insights.companies
            .filter { !$0.isSilent }
            .sorted { ($0.lastReplyAt ?? .distantPast) > ($1.lastReplyAt ?? .distantPast) }

        // One row per person, carrying their most recent unanswered send. The
        // feed holds a row per send, and a follow-up queue that lists the same
        // contact three times is three mails to the same inbox.
        var latestByContact: [Contact.ID: ActivityEntry] = [:]
        for entry in insights.unanswered {
            let held = latestByContact[entry.contact.id]
            if held == nil || (entry.date ?? .distantPast) > (held?.date ?? .distantPast) {
                latestByContact[entry.contact.id] = entry
            }
        }
        insights.waitingMails = latestByContact.values
            .map { entry in
                let days = entry.date.map {
                    Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0
                } ?? 0
                return WaitingMail(contact: entry.contact, company: entry.company,
                                   companyID: idByName[entry.company], sentAt: entry.date,
                                   days: days)
            }
            .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }

        let waits = insights.replies.compactMap { entry -> Int? in
            guard let sent = entry.date, let replied = entry.contact.repliedAt else { return nil }
            return Calendar.current.dateComponents([.day], from: sent, to: replied).day
        }.sorted()
        insights.medianResponseDays = waits.isEmpty ? nil : waits[waits.count / 2]

        return insights
    }
}
