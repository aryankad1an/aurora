import SwiftUI
import WidgetKit

/// One moment of the widgets' timeline: the snapshot as it reads on `date`'s
/// day, or nil before the app has written one (signed out, never opened).
nonisolated struct AuroraEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let savedAt: Date?

    /// Made-up figures for the widget gallery and the placeholder.
    static let sample = AuroraEntry(date: .now, snapshot: .sample, savedAt: .now)
}

/// Reads what the app left in the App Group. The timeline adds an entry when
/// a scheduled batch comes due and one at midnight, when the days move on; the
/// app asks for a fresh one whenever its numbers change.
nonisolated struct AuroraProvider: TimelineProvider {
    func placeholder(in context: Context) -> AuroraEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (AuroraEntry) -> Void) {
        let saved = WidgetShelf.load()
        // The gallery shows the sample until there's something of the user's.
        if context.isPreview, saved == nil { return completion(.sample) }
        completion(Self.entry(saved, at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuroraEntry>) -> Void) {
        let saved = WidgetShelf.load()
        let now = Date.now
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        var dates = [now, midnight]
        if let due = saved?.snapshot.next?.at, due > now, due < midnight { dates.append(due) }
        let entries = dates.sorted().map { Self.entry(saved, at: $0) }
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    private static func entry(_ saved: WidgetShelf.Saved?, at date: Date) -> AuroraEntry {
        AuroraEntry(date: date, snapshot: saved?.snapshot.aligned(to: date), savedAt: saved?.savedAt)
    }
}

/// Aurora at a glance: the week as a striped sunset — one band a day, brighter
/// the more mail went — with the reply rate, the streak and what the queue
/// sends next. Every size, on the Home Screen and the Lock Screen.
struct AuroraPulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShelf.pulseKind, provider: AuroraProvider()) { entry in
            PulseView(entry: entry)
                .containerBackground(for: .widget) { WidgetGround() }
                .widgetURL(URL(string: "aurora://home"))
        }
        .configurationDisplayName("Aurora")
        .description("Your week of outreach as a sunset, with replies, your streak and the next send.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Who wrote back, newest first. Names are hidden while the phone is locked.
struct AuroraRepliesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShelf.repliesKind, provider: AuroraProvider()) { entry in
            RepliesView(entry: entry)
                .containerBackground(for: .widget) { WidgetGround() }
                .widgetURL(URL(string: "aurora://activity/replied"))
        }
        .configurationDisplayName("Replies")
        .description("The people who wrote back, newest first.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

nonisolated extension WidgetSnapshot {
    /// The gallery's made-up week.
    static let sample: WidgetSnapshot = {
        let now = Date.now
        let today = Calendar.current.startOfDay(for: now)
        return WidgetSnapshot(
            day: today,
            sent: [6, 0, 12, 9, 0, 0, 14, 8, 22, 0, 17, 11, 5, 9],
            replies: [0, 1, 0, 0, 2, 0, 0, 1, 0, 3, 0, 1, 0, 2],
            mailsSent: 214, peopleMailed: 186, peopleReplied: 31,
            streak: 3, streakEnd: today,
            latestReplies: [
                Reply(id: "1", name: "Maya Fernandes", company: "Northwind", at: now.addingTimeInterval(-40 * 60)),
                Reply(id: "2", name: "Leo Brandt", company: "Contoso Labs", at: now.addingTimeInterval(-5 * 3600)),
                Reply(id: "3", name: "Priya Nair", company: "Fabrikam", at: now.addingTimeInterval(-26 * 3600)),
                Reply(id: "4", name: "Sam Okafor", company: "Tailspin", at: now.addingTimeInterval(-50 * 3600)),
                Reply(id: "5", name: "Ana Ruiz", company: "Litware", at: now.addingTimeInterval(-74 * 3600)),
                Reply(id: "6", name: "Chen Wei", company: "Proseware", at: now.addingTimeInterval(-98 * 3600)),
            ],
            next: NextSend(state: .scheduled, title: "Not mailed yet", at: now.addingTimeInterval(3 * 3600), mails: 24),
            waiting: 24, bounced: 1, tracked: 12)
    }()
}
