import SwiftUI
import WidgetKit

extension WidgetSnapshot {
    /// The widgets' view of this account, from what the app has loaded: the
    /// send history for the counts, the Activity feed for who replied, and the
    /// queue for what goes next.
    init(sends: [MailSend], activity: [ActivityEntry], batches: [MailBatch], runningBatchID: UUID?,
         bounced: Int, tracked: Int, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        func index(_ date: Date) -> Int? {
            let back = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? .max
            return (0..<Self.days).contains(back) ? Self.days - 1 - back : nil
        }
        var sent = Array(repeating: 0, count: Self.days)
        var replies = Array(repeating: 0, count: Self.days)
        var sendDays = Set<Date>()
        var mailed = Set<String>(), replied = Set<String>()
        for send in sends {
            mailed.insert(send.contactID)
            if let at = send.sentAt {
                sendDays.insert(calendar.startOfDay(for: at))
                if let i = index(at) { sent[i] += 1 }
            }
            if let at = send.repliedAt {
                replied.insert(send.contactID)
                if let i = index(at) { replies[i] += 1 }
            }
        }

        // Back from the last day anything went, a day at a time.
        var streak = 0
        let streakEnd = sendDays.max()
        if var day = streakEnd {
            while sendDays.contains(day) {
                streak += 1
                guard let before = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = before
            }
        }

        var seen = Set<String>()
        let latest = activity
            .compactMap { entry -> Reply? in
                guard let at = entry.contact.repliedAt, seen.insert(entry.contact.id).inserted else { return nil }
                // A name, never an address: the widget is on the Lock Screen.
                let name = entry.contact.name.isEmpty ? "Someone" : entry.contact.name
                return Reply(id: entry.contact.id, name: name, company: entry.company, at: at)
            }
            .sorted { $0.at > $1.at }
            .prefix(Self.replyLimit)

        let working = batches.filter(\.hasWork)
        let next: NextSend? = working.first { $0.id == runningBatchID }
            .map { NextSend(state: .sending, title: $0.title, mails: $0.pending) }
            ?? working.filter { $0.isScheduled(at: now) }
                .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
                .map { NextSend(state: .scheduled, title: $0.title, at: $0.scheduledFor, mails: $0.pending) }
            ?? working.first
                .map { NextSend(state: $0.isDue(at: now) ? .scheduled : .paused, title: $0.title,
                                at: $0.scheduledFor, mails: $0.pending) }

        self.init(day: today, sent: sent, replies: replies, mailsSent: sends.count,
                  peopleMailed: mailed.count, peopleReplied: replied.count,
                  streak: streak, streakEnd: streakEnd, latestReplies: Array(latest),
                  next: next, waiting: working.reduce(0) { $0 + $1.pending },
                  bounced: bounced, tracked: tracked)
    }
}

extension WidgetShelf {
    /// Save `snapshot` and, when it changed, have the widgets drawn again.
    static func publish(_ snapshot: WidgetSnapshot) {
        if save(snapshot) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Replies a check found with the app closed: the widgets show them
    /// before the app has been opened to reload.
    static func publish(found: [ReplySync.Found], at date: Date = .now) {
        guard var snapshot = load()?.snapshot else { return }
        snapshot.add(replies: found.map {
            WidgetSnapshot.Reply(id: $0.contactID, name: personName($0.name), company: $0.company ?? "", at: date)
        })
        publish(snapshot)
    }

    /// A reply with no name on file is named by who it came from, which can be
    /// an address: the widget shows the name in it, or no one.
    private static func personName(_ from: String) -> String {
        let name = from.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces.union(["\""])) } ?? ""
        return name.isEmpty || name.contains("@") ? "Someone" : name
    }

    /// Signed out: nothing of the account is left for the widgets to show.
    static func signOut() {
        clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Keeps the widgets' copy current. Draws nothing: it works the snapshot out
/// again whenever what it's made from changes, and saves it a moment after
/// the changes stop, so a batch going out doesn't redraw the widgets per mail.
struct WidgetPublisher: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(MailQueue.self) private var mailQueue
    @Environment(ReplySync.self) private var replySync

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: snapshot) {
                guard let snapshot else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                WidgetShelf.publish(snapshot)
            }
    }

    /// Nil until the history and the Activity feed have both loaded: a
    /// snapshot of a half-loaded account would show the widgets zeros.
    private var snapshot: WidgetSnapshot? {
        guard jobStore.hasLoaded, !jobStore.isLoading, !jobStore.isLoadingActivity else { return nil }
        return WidgetSnapshot(sends: jobStore.sends, activity: jobStore.activity,
                              batches: mailQueue.batches, runningBatchID: mailQueue.runningBatchID,
                              bounced: jobStore.bouncedContacts(from: replySync).count,
                              tracked: jobStore.jobs.count)
    }
}
