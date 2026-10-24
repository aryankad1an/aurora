import Foundation

// The widgets' snapshot: days sliding out, the streak, replies found in the
// background, and the copy in the App Group. Run with:
//
//   swiftc -parse-as-library Shared/WidgetSnapshot.swift Tests/WidgetSnapshotTests.swift -o /tmp/ws && /tmp/ws

@main
struct WidgetSnapshotTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    static func day(_ offset: Int, hour: Int = 12) -> Date {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        return calendar.date(byAdding: DateComponents(day: offset, hour: hour), to: start)!
    }

    static func snapshot(sent: [Int] = Array(1...14), replies: [Int] = Array(repeating: 0, count: 14),
                         latest: [WidgetSnapshot.Reply] = []) -> WidgetSnapshot {
        WidgetSnapshot(day: calendar.startOfDay(for: day(0)), sent: sent, replies: replies,
                       mailsSent: 105, peopleMailed: 100, peopleReplied: 20,
                       streak: 4, streakEnd: calendar.startOfDay(for: day(0)),
                       latestReplies: latest, next: nil, waiting: 0, bounced: 0, tracked: 3)
    }

    static func reply(_ id: String, _ at: Date) -> WidgetSnapshot.Reply {
        WidgetSnapshot.Reply(id: id, name: "Person \(id)", company: "Acme", at: at)
    }

    static func main() {
        // Days that pass slide out of the counts.
        let base = snapshot()
        expect(base.aligned(to: day(0, hour: 23), calendar: calendar), base, "same day: unchanged")
        expect(base.aligned(to: day(-1), calendar: calendar), base, "an earlier day: unchanged")
        let twoOn = base.aligned(to: day(2), calendar: calendar)
        expect(twoOn.sent, Array(3...14) + [0, 0], "two days on: oldest two out, two empty days in")
        expect(twoOn.day, calendar.startOfDay(for: day(2)), "two days on: the day moves")
        expect(twoOn.replies.count, WidgetSnapshot.days, "two days on: replies keep their length")
        expect(base.aligned(to: day(30), calendar: calendar).sent, Array(repeating: 0, count: 14), "a month on: all empty")

        // This week and the rate.
        expect(base.sentThisWeek, (8...14).reduce(0, +), "this week is the last seven days")
        expect(base.replyRate, 0.2, "20 of 100 wrote back")
        var nobody = base
        nobody.peopleMailed = 0
        expect(nobody.replyRate, 0, "no one mailed: no rate")

        // The streak lives through the day after its last send.
        expect(base.currentStreak(on: day(0), calendar: calendar), 4, "streak on its last day")
        expect(base.currentStreak(on: day(1, hour: 23), calendar: calendar), 4, "streak the next day")
        expect(base.currentStreak(on: day(2, hour: 0), calendar: calendar), 0, "broken two days on")
        var none = base
        none.streakEnd = nil
        expect(none.currentStreak(on: day(0), calendar: calendar), 0, "nothing sent: no streak")

        // Replies a background check found.
        var withReplies = snapshot(latest: [reply("a", day(-1))])
        withReplies.add(replies: [reply("b", day(0, hour: 14)), reply("a", day(0, hour: 15))], calendar: calendar)
        expect(withReplies.latestReplies.map(\.id), ["b", "a"], "new first, someone already listed not twice")
        expect(withReplies.replies.last, 1, "today's replies count the new one")
        expect(withReplies.peopleReplied, 21, "one more person wrote back")

        var nextDay = snapshot()
        nextDay.add(replies: [reply("c", day(1, hour: 9))], calendar: calendar)
        expect(nextDay.day, calendar.startOfDay(for: day(1)), "a reply the next day moves the day on")
        expect(nextDay.replies.last, 1, "and lands on the new day")
        expect(nextDay.sent.last, 0, "which has nothing sent yet")

        var full = snapshot(latest: (1...6).map { reply("\($0)", day(-$0)) })
        full.add(replies: [reply("new", day(0, hour: 13))], calendar: calendar)
        expect(full.latestReplies.count, WidgetSnapshot.replyLimit, "the list keeps its limit")
        expect(full.latestReplies.first?.id, "new", "with the newest on top")

        var capped = snapshot()
        capped.peopleReplied = capped.peopleMailed
        capped.add(replies: [reply("d", day(0, hour: 13))], calendar: calendar)
        expect(capped.peopleReplied, capped.peopleMailed, "never more replied than mailed")

        var unchanged = snapshot(latest: [reply("a", day(-1))])
        unchanged.add(replies: [reply("a", day(0, hour: 13))], calendar: calendar)
        expect(unchanged, snapshot(latest: [reply("a", day(-1))]), "only known replies: nothing changes")

        // Round trip through JSON, as the shelf stores it.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var rich = snapshot(latest: [reply("a", day(-1))])
        rich.next = WidgetSnapshot.NextSend(state: .scheduled, title: "Adobe", at: day(0, hour: 20), mails: 12)
        let saved = WidgetShelf.Saved(savedAt: day(0), snapshot: rich)
        let decoded = try? decoder.decode(WidgetShelf.Saved.self, from: encoder.encode(saved))
        expect(decoded?.snapshot, rich, "survives the round trip")
        expect(decoded?.savedAt, day(0), "with when it was saved")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
