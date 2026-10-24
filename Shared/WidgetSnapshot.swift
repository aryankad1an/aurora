import Foundation

/// What the home-screen and Lock Screen widgets show: the app works it out from
/// what it has loaded and leaves it in the App Group's container
/// (`WidgetShelf`), where the widget extension reads it.
///
/// Only what a notification already shows — counts, company names and who
/// wrote back. No addresses, subjects or reply text: the vault seals those,
/// and this file isn't sealed.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// The start of the day the daily counts end on.
    var day: Date
    /// Mails sent each day, oldest first and `day` last: `WidgetSnapshot.days` of them.
    var sent: [Int]
    /// Replies that arrived each day, lined up with `sent`.
    var replies: [Int]
    /// All time: mails sent, people mailed, and how many of them wrote back.
    var mailsSent: Int
    var peopleMailed: Int
    var peopleReplied: Int
    /// Days in a row with mail sent, ending on `streakEnd`.
    var streak: Int
    var streakEnd: Date?
    /// Who wrote back most recently, newest first.
    var latestReplies: [Reply]
    /// The next send the queue has: going now, paused, or waiting for its time.
    var next: NextSend?
    /// Mails waiting in the queue, across every batch.
    var waiting: Int
    /// Addresses that bounced and haven't been dealt with.
    var bounced: Int
    /// Companies tracked on Home.
    var tracked: Int

    /// How many days of counts are kept.
    static let days = 14
    /// How many replies are kept: the large Replies widget's rows.
    static let replyLimit = 6

    struct Reply: Codable, Equatable, Sendable, Identifiable {
        /// The contact's id: one row per person, however often they replied.
        var id: String
        var name: String
        var company: String
        var at: Date
    }

    struct NextSend: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case sending, paused, scheduled }
        var state: State
        /// The batch's name: "Adobe", "Not mailed yet".
        var title: String
        /// When a scheduled batch goes.
        var at: Date?
        /// Mails still to go in it.
        var mails: Int
    }

    /// The counts as of `date`'s day: days that have passed since the snapshot
    /// was written slide out, and the new ones are empty.
    func aligned(to date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: date)
        let shift = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        guard shift > 0 else { return self }
        var copy = self
        copy.day = today
        func slide(_ counts: [Int]) -> [Int] {
            Array((counts + Array(repeating: 0, count: min(shift, Self.days))).suffix(Self.days))
        }
        copy.sent = slide(sent)
        copy.replies = slide(replies)
        return copy
    }

    /// The last `count` days' sends (or replies), oldest first.
    func recent(_ counts: [Int], days count: Int) -> [Int] { Array(counts.suffix(count)) }

    var sentThisWeek: Int { recent(sent, days: 7).reduce(0, +) }
    var repliesThisWeek: Int { recent(replies, days: 7).reduce(0, +) }

    /// Of everyone mailed, the share who wrote back: 0…1.
    var replyRate: Double {
        peopleMailed == 0 ? 0 : Double(peopleReplied) / Double(peopleMailed)
    }

    /// The streak as it stands on `date`: still alive through the day after its
    /// last send, broken after that.
    func currentStreak(on date: Date, calendar: Calendar = .current) -> Int {
        guard let streakEnd else { return 0 }
        let gap = calendar.dateComponents([.day], from: streakEnd, to: calendar.startOfDay(for: date)).day ?? 0
        return gap <= 1 ? streak : 0
    }

    /// Replies found by a check the app ran by itself, before the app has
    /// reloaded: the counts and the list take them in now.
    mutating func add(replies found: [Reply], calendar: Calendar = .current) {
        let fresh = found.filter { reply in !latestReplies.contains { $0.id == reply.id } }
        guard !fresh.isEmpty, let last = fresh.map(\.at).max() else { return }
        self = aligned(to: last, calendar: calendar)
        replies[replies.count - 1] += fresh.count
        peopleReplied = min(peopleReplied + fresh.count, peopleMailed)
        latestReplies = Array((fresh.sorted { $0.at > $1.at } + latestReplies).prefix(Self.replyLimit))
    }
}

/// The widgets' copy of the snapshot, in the App Group's container: written by
/// the app, read by the widget extension.
nonisolated enum WidgetShelf {
    static let appGroup = "group.com.realaryan.JTracker"
    static let pulseKind = "AuroraPulse"
    static let repliesKind = "AuroraReplies"

    struct Saved: Codable, Sendable {
        var savedAt: Date
        var snapshot: WidgetSnapshot
    }

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget.json")
    }

    static func load() -> Saved? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Saved.self, from: data)
    }

    /// Saves `snapshot`, returning whether it differed from what was there.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot, at date: Date = .now) -> Bool {
        guard let file, load()?.snapshot != snapshot else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Saved(savedAt: date, snapshot: snapshot)) else { return false }
        // Readable to the widgets once the phone has been unlocked after a
        // restart, which is when they're drawn.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    /// Signed out: the widgets go back to asking for the app.
    static func clear() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
