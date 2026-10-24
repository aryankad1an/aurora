import SwiftUI
import WidgetKit

// MARK: - Aurora (the pulse)

struct PulseView: View {
    let entry: AuroraEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        } else {
            SignedOutView()
        }
    }

    @ViewBuilder
    private func content(_ s: WidgetSnapshot) -> some View {
        switch family {
        case .systemMedium: PulseMedium(s: s, date: entry.date)
        case .systemLarge: PulseLarge(s: s, date: entry.date, savedAt: entry.savedAt)
        case .systemExtraLarge: PulseExtraLarge(s: s, date: entry.date, savedAt: entry.savedAt)
        case .accessoryCircular: PulseCircular(s: s)
        case .accessoryRectangular: PulseRectangular(s: s, date: entry.date)
        case .accessoryInline: PulseInline(s: s, date: entry.date)
        default: PulseSmall(s: s, date: entry.date)
        }
    }
}

private struct PulseSmall: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                WidgetHeader()
                Spacer(minLength: 0)
                StreakBadge(days: s.currentStreak(on: date))
            }
            Spacer(minLength: 4)
            Text(percent(s.replyRate))
                .font(.display(34))
                .foregroundStyle(.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("\(s.peopleReplied) of \(s.peopleMailed) wrote back")
                .font(.caption2)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            WeekSun(days: s.recent(s.sent, days: 7))
                .frame(height: 34)
            Text("\(s.sentThisWeek) sent this week")
                .font(.caption2)
                .foregroundStyle(.inkFaint)
                .lineLimit(1)
                .padding(.top, 3)
        }
    }
}

private struct PulseMedium: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader()
                Spacer(minLength: 6)
                WeekSun(days: s.recent(s.sent, days: 7))
                    .frame(height: 62)
                Text("Today on the horizon")
                    .font(.caption2)
                    .foregroundStyle(.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 120)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Stat(value: "\(s.sentThisWeek)", label: "sent")
                    Stat(value: "\(s.repliesThisWeek)", label: "replies", tint: .olive)
                    Stat(value: percent(s.replyRate), label: "wrote back")
                }
                Text("Last 7 days")
                    .font(.caption2)
                    .foregroundStyle(.inkFaint)
                    .padding(.top, 2)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 4) {
                    if s.bounced > 0 { BounceLine(count: s.bounced) }
                    NextSendLine(next: s.next, date: date)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The large widget's top half, shared with the extra large one.
private struct PulseSummary: View {
    let s: WidgetSnapshot
    let date: Date
    let savedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetHeader()
                Spacer(minLength: 4)
                if let savedAt {
                    Text("Updated \(when(savedAt, from: date))")
                        .font(.caption2)
                        .foregroundStyle(.inkFaint)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                WeekSun(days: s.recent(s.sent, days: 7))
                    .frame(width: 112, height: 54)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(percent(s.replyRate))
                        .font(.display(34))
                        .foregroundStyle(.ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("\(s.peopleReplied) of \(s.peopleMailed) wrote back")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            HStack(alignment: .top) {
                Stat(value: "\(s.sentThisWeek)", label: "sent · 7 days")
                Spacer(minLength: 6)
                Stat(value: "\(s.repliesThisWeek)", label: "replies", tint: .olive)
                Spacer(minLength: 6)
                Stat(value: "\(s.currentStreak(on: date))", label: "day streak", tint: .kraft)
                Spacer(minLength: 6)
                Stat(value: "\(s.tracked)", label: "tracked")
            }
            VStack(spacing: 3) {
                DayBars(sent: s.sent, replies: s.replies)
                    .frame(height: 40)
                HStack {
                    Text("2 weeks ago")
                    Spacer()
                    Text("Today")
                }
                .font(.caption2)
                .foregroundStyle(.inkFaint)
            }
        }
    }
}

private struct PulseLarge: View {
    let s: WidgetSnapshot
    let date: Date
    let savedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PulseSummary(s: s, date: date, savedAt: savedAt)
            Rectangle().fill(Color.hairline).frame(height: 1)
            Link(destination: URL(string: "aurora://activity/replied")!) {
                ReplyList(replies: Array(s.latestReplies.prefix(2)), date: date, spacing: 6, emptyNote: "No replies yet")
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                NextSendLine(next: s.next, date: date)
                Spacer(minLength: 0)
                if s.bounced > 0 { BounceLine(count: s.bounced, compact: true) }
            }
        }
    }
}

private struct PulseExtraLarge: View {
    let s: WidgetSnapshot
    let date: Date
    let savedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                PulseSummary(s: s, date: date, savedAt: savedAt)
                Spacer(minLength: 0)
                if s.bounced > 0 { BounceLine(count: s.bounced) }
                NextSendLine(next: s.next, date: date)
            }
            Rectangle().fill(Color.hairline).frame(width: 1)
            Link(destination: URL(string: "aurora://activity/replied")!) {
                ReplyList(replies: Array(s.latestReplies.prefix(5)), date: date, emptyNote: "No replies yet")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct PulseCircular: View {
    let s: WidgetSnapshot

    var body: some View {
        Gauge(value: s.replyRate) {
            Image(systemName: "arrowshape.turn.up.left.fill")
        } currentValueLabel: {
            Text(percent(s.replyRate))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel("\(percent(s.replyRate)) of the people you mailed wrote back")
    }
}

private struct PulseRectangular: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Aurora", systemImage: "sun.horizon.fill")
                .font(.headline)
                .widgetAccentable()
            Text("\(s.repliesThisWeek) replies · \(s.sentThisWeek) sent")
                .font(.caption)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detail: String {
        if let next = s.next {
            switch next.state {
            case .sending: return "Sending · \(next.mails) left"
            case .paused: return "Queue paused · \(next.mails) waiting"
            case .scheduled:
                if let at = next.at, at > date { return "Next send \(sendTime(at, from: date))" }
                return "Due now · \(next.mails) mails"
            }
        }
        let streak = s.currentStreak(on: date)
        return streak > 1 ? "\(streak)-day streak" : "\(percent(s.replyRate)) wrote back"
    }
}

private struct PulseInline: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        if let next = s.next, next.state == .scheduled, let at = next.at, at > date {
            Label("Aurora sends \(sendTime(at, from: date))", systemImage: "sun.horizon.fill")
        } else {
            Label("\(s.repliesThisWeek) replies · \(percent(s.replyRate))", systemImage: "sun.horizon.fill")
        }
    }
}

// MARK: - Replies

struct RepliesView: View {
    let entry: AuroraEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            Group {
                switch family {
                case .systemMedium: RepliesList(s: s, date: entry.date, limit: 3)
                case .systemLarge: RepliesList(s: s, date: entry.date, limit: WidgetSnapshot.replyLimit)
                case .accessoryRectangular: RepliesRectangular(s: s, date: entry.date)
                default: LatestReply(s: s, date: entry.date)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        } else {
            SignedOutView()
        }
    }
}

/// The small Replies widget: the one who wrote back last, large.
private struct LatestReply: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption2)
                    .foregroundStyle(.olive)
                    .widgetAccentable()
                Text("REPLIED")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.olive)
                    .widgetAccentable()
                Spacer(minLength: 0)
                if let reply = s.latestReplies.first {
                    Text(when(reply.at, from: date))
                        .font(.caption2)
                        .foregroundStyle(.inkFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let reply = s.latestReplies.first {
                Monogram(name: reply.name, size: 32)
                Text(reply.name)
                    .font(.display(19))
                    .foregroundStyle(.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .privacySensitive()
                    .padding(.top, 6)
                if !reply.company.isEmpty {
                    Text(reply.company)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
            } else {
                Text("No replies yet")
                    .font(.display(19))
                    .foregroundStyle(.ink)
                Text("\(s.peopleMailed) mailed so far")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 6)
            Text("\(s.repliesThisWeek) this week · \(s.peopleReplied) in all")
                .font(.caption2)
                .foregroundStyle(.inkFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct RepliesList: View {
    let s: WidgetSnapshot
    let date: Date
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: limit > 3 ? 12 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Replies")
                    .font(.display(18))
                    .foregroundStyle(.ink)
                Spacer(minLength: 4)
                Text("\(s.peopleReplied) of \(s.peopleMailed) wrote back")
                    .font(.caption2)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }
            ReplyList(replies: Array(s.latestReplies.prefix(limit)), date: date, showsTitle: false,
                      spacing: limit > 3 ? 10 : 5, emptyNote: "No replies yet. \(s.peopleMailed) mailed so far.")
            Spacer(minLength: 0)
            if limit > 3 {
                Rectangle().fill(Color.hairline).frame(height: 1)
                HStack(alignment: .bottom, spacing: 16) {
                    Stat(value: "\(s.repliesThisWeek)", label: "this week", tint: .olive)
                    Stat(value: percent(s.replyRate), label: "wrote back")
                    Spacer(minLength: 0)
                    WeekSun(days: s.recent(s.sent, days: 7))
                        .frame(width: 72, height: 36)
                }
            }
        }
    }
}

private struct RepliesRectangular: View {
    let s: WidgetSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let reply = s.latestReplies.first {
                Label(reply.name, systemImage: "arrowshape.turn.up.left.fill")
                    .font(.headline)
                    .widgetAccentable()
                    .privacySensitive()
                Text(reply.company.isEmpty ? "Replied" : reply.company)
                    .font(.caption)
                Text("\(when(reply.at, from: date)) · \(s.repliesThisWeek) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("No replies yet", systemImage: "arrowshape.turn.up.left")
                    .font(.headline)
                    .widgetAccentable()
                Text("\(s.peopleMailed) mailed so far")
                    .font(.caption)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

/// The ground every Home Screen widget sits on: the app's black, with the
/// sun's glow low on the horizon.
struct WidgetGround: View {
    var body: some View {
        ZStack {
            Color.paper
            RadialGradient(colors: [Color.clay.opacity(0.09), .clear],
                           center: .bottom, startRadius: 0, endRadius: 180)
        }
    }
}

/// The mark and the name.
private struct WidgetHeader: View {
    var body: some View {
        HStack(spacing: 4) {
            AuroraMark(accent: .clay, bead: .ink, line: .inkFaint)
                .frame(width: 18, height: 18)
            Text("AURORA")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.clay)
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aurora")
    }
}

/// The last seven days as a seventies sunset: a half sun on the horizon cut
/// into one band a day, the oldest at the top and today on the horizon. A
/// band is as bright as that day was busy; a day with nothing sent is a
/// ghost of one.
struct WeekSun: View {
    /// Mails sent each day, oldest first.
    let days: [Int]

    var body: some View {
        Canvas { context, size in
            let count = days.count
            guard count > 0 else { return }
            let radius = min(size.width / 2, size.height - 1)
            let center = CGPoint(x: size.width / 2, y: size.height - 1)
            var disc = Path()
            disc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            disc.closeSubpath()

            // The slits between bands widen toward the horizon, as on the mark.
            let gaps = (0..<(count - 1)).map { radius * (0.016 + 0.01 * Double($0)) }
            let band = (radius - gaps.reduce(0, +)) / Double(count)
            let peak = Double(max(days.max() ?? 0, 1))
            var sun = context
            sun.clip(to: disc)
            var top = center.y - radius
            for (i, sent) in days.enumerated() {
                let colour = Palette.stripes[min(i * Palette.stripes.count / count, Palette.stripes.count - 1)]
                let opacity = sent == 0 ? 0.14 : 0.42 + 0.58 * Double(sent) / peak
                sun.fill(Path(CGRect(x: center.x - radius, y: top, width: radius * 2, height: band)),
                         with: .color(colour.opacity(opacity)))
                top += band + (i < gaps.count ? gaps[i] : 0)
            }

            var horizon = Path()
            horizon.move(to: CGPoint(x: 0, y: center.y))
            horizon.addLine(to: CGPoint(x: size.width, y: center.y))
            context.stroke(horizon, with: .color(Palette.inkFaint), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .widgetAccentable()
        .accessibilityElement()
        .accessibilityLabel("Mail sent over the last 7 days: \(days.map(String.init).joined(separator: ", ")), today last")
    }
}

/// Two weeks of sends as bars in the ident's stripes, with a bead over each
/// day for every reply that came in on it.
private struct DayBars: View {
    let sent: [Int]
    let replies: [Int]

    var body: some View {
        Canvas { context, size in
            let count = sent.count
            guard count > 0 else { return }
            let beadRoom: CGFloat = 12
            let gap: CGFloat = 4
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let peak = CGFloat(max(sent.max() ?? 0, 1))
            let barRoom = size.height - beadRoom
            let fill = GraphicsContext.Shading.linearGradient(
                Gradient(colors: Palette.stripes),
                startPoint: CGPoint(x: 0, y: beadRoom), endPoint: CGPoint(x: 0, y: size.height))
            for i in 0..<count {
                let x = CGFloat(i) * (width + gap)
                let height = sent[i] == 0 ? 2 : max(4, barRoom * CGFloat(sent[i]) / peak)
                let bar = Path(roundedRect: CGRect(x: x, y: size.height - height, width: width, height: height),
                               cornerRadius: min(width / 2, 3))
                if sent[i] == 0 {
                    context.fill(bar, with: .color(Palette.hairline))
                } else {
                    context.fill(bar, with: fill)
                }
                // A bead per reply, up to three, stacked over the bar.
                let beads = min(replies[safe: i] ?? 0, 3)
                let bead = min(width, 5)
                for k in 0..<beads {
                    let y = size.height - height - 3 - bead - CGFloat(k) * (bead + 1.5)
                    context.fill(Path(ellipseIn: CGRect(x: x + (width - bead) / 2, y: max(y, 0), width: bead, height: bead)),
                                 with: .color(Palette.olive))
                }
            }
        }
        .widgetAccentable()
        .accessibilityElement()
        .accessibilityLabel("Mail sent each day for two weeks, \(sent.reduce(0, +)) in all, with \(replies.reduce(0, +)) replies")
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.display(22))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StreakBadge: View {
    let days: Int

    var body: some View {
        if days > 1 {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                Text("\(days)")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.kraft)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(days)-day streak")
        }
    }
}

private struct ReplyList: View {
    let replies: [WidgetSnapshot.Reply]
    let date: Date
    var showsTitle = true
    var spacing: CGFloat = 8
    let emptyNote: String

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if showsTitle {
                Text("LATEST REPLIES")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.olive)
            }
            if replies.isEmpty {
                Text(emptyNote)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }
            ForEach(replies) { reply in
                ReplyRow(reply: reply, date: date)
            }
        }
    }
}

private struct ReplyRow: View {
    let reply: WidgetSnapshot.Reply
    let date: Date

    var body: some View {
        HStack(spacing: 9) {
            Monogram(name: reply.name, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(reply.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .privacySensitive()
                if !reply.company.isEmpty {
                    Text(reply.company)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Text(when(reply.at, from: date))
                .font(.caption2)
                .foregroundStyle(.olive)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Initials in an olive ring, for a person who replied.
private struct Monogram: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .serif))
            .foregroundStyle(.olive)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.olive.opacity(0.16)))
            .overlay(Circle().strokeBorder(Color.olive.opacity(0.45), lineWidth: 1))
            .privacySensitive()
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

private struct NextSendLine: View {
    let next: WidgetSnapshot.NextSend?
    let date: Date

    var body: some View {
        Link(destination: URL(string: "aurora://activity")!) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(next == nil ? Color.inkFaint : Color.clay)
                    .widgetAccentable()
                Text(text)
                    .foregroundStyle(next == nil ? Color.inkMuted : Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption)
        }
    }

    private var symbol: String {
        switch next?.state {
        case .sending: "paperplane.fill"
        case .paused: "pause.circle.fill"
        case .scheduled: "clock.fill"
        case nil: "checkmark.circle"
        }
    }

    private var text: String {
        guard let next else { return "Nothing waiting to send" }
        let mails = next.mails == 1 ? "1 mail" : "\(next.mails) mails"
        switch next.state {
        case .sending: return "Sending · \(next.mails) left"
        case .paused: return "Paused · \(mails) waiting"
        case .scheduled:
            if let at = next.at, at > date { return "Sends \(sendTime(at, from: date)) · \(mails)" }
            return "Due now · \(mails)"
        }
    }
}

private struct BounceLine: View {
    let count: Int
    /// Just the count, beside the next send.
    var compact = false

    var body: some View {
        Link(destination: URL(string: "aurora://activity/bounced")!) {
            Label(compact ? "\(count) bounced" : count == 1 ? "1 address bounced" : "\(count) addresses bounced",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.danger)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Before the app has written anything: signed out, or never opened.
private struct SignedOutView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Open Aurora", systemImage: "sun.horizon.fill")
        case .accessoryCircular:
            Image(systemName: "sun.horizon.fill")
                .font(.title2)
                .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Aurora", systemImage: "sun.horizon.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text("Open Aurora to sign in")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                AuroraMark(accent: .clay, bead: .ink, line: .inkFaint)
                    .frame(width: 44, height: 44)
                Spacer(minLength: 0)
                Text("Open Aurora to see your week here.")
                    .font(.subheadline)
                    .foregroundStyle(.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Formatting

/// "17%".
private func percent(_ share: Double) -> String {
    share.formatted(.percent.precision(.fractionLength(0)))
}

/// When something happened, to the day: a time today, then "Yesterday", a
/// weekday this week, and a date before that. Coarse on purpose — it's drawn
/// once per timeline entry, and a day stays true until midnight's entry.
private func when(_ moment: Date, from now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(moment, inSameDayAs: now) { return moment.formatted(date: .omitted, time: .shortened) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(moment, inSameDayAs: yesterday) {
        return "Yesterday"
    }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: moment), to: calendar.startOfDay(for: now)).day ?? 0
    return days < 7 ? moment.formatted(.dateTime.weekday(.abbreviated)) : moment.formatted(.dateTime.month(.abbreviated).day())
}

/// When a scheduled send goes: a time today, else the weekday and time.
private func sendTime(_ moment: Date, from now: Date) -> String {
    Calendar.current.isDate(moment, inSameDayAs: now)
        ? moment.formatted(date: .omitted, time: .shortened)
        : moment.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
