import ActivityKit
import SwiftUI
import WidgetKit

/// The mail queue on the Lock Screen and in the Dynamic Island: what's
/// sending and to whom, how far it's got, and — when the run is waiting on
/// Gmail or on a connection — a countdown to when it carries on. A scheduled
/// batch shows when it goes; once its time has come, a Send Now button.
/// Tapping anywhere else opens Activity's Queued lane.
struct SendLiveActivityWidget: Widget {
    static let openURL = URL(string: "aurora://activity/queued")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SendActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.openURL)
        } dynamicIsland: { context in
            let style = Style(context.attributes)
            let state = context.state
            let ready = Phrase.isReady(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Tile(phase: state.phase, style: style, size: 40)
                        .padding(.leading, 4)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Tally(state: state, isStale: context.isStale)
                        .padding(.trailing, 4)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // What's happening, then which batch — each on its own line,
                    // so a long batch name never pushes the count.
                    VStack(alignment: .leading, spacing: 3) {
                        Headline(state: state, style: style, isStale: context.isStale)
                            .font(.subheadline.weight(.semibold))
                        BatchName(title: state.title)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.phase == .scheduled {
                            ScheduledDetail(state: state, style: style, ready: ready, compact: true)
                        } else if state.recipient != nil {
                            // Who it's to, then the bar: the count above says
                            // how many have gone, and the island has room for
                            // two lines under the headline, not three.
                            Recipient(state: state, style: style, compact: true)
                            Meter(state: state, style: style)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Meter(state: state, style: style)
                                Legend(state: state, style: style)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                Glyph(phase: state.phase, style: style, size: 13)
                    .padding(.leading, 4)
            } compactTrailing: {
                CompactTrailing(state: state, style: style, ready: ready)
                    .padding(.trailing, 4)
            } minimal: {
                if state.phase == .scheduled {
                    Glyph(phase: state.phase, style: style, size: 12)
                } else {
                    Gauge(value: state.fraction) {
                        Glyph(phase: state.phase, style: style, size: 10)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(style.accent)
                }
            }
            .contentMargins(.all, 14, for: .expanded)
            .widgetURL(Self.openURL)
            .keylineTint(style.accent)
        }
    }
}

/// The theme's colours, as the activity carried them.
private struct Style {
    let accent: Color
    let reply: Color
    let attention: Color

    init(_ attributes: SendActivityAttributes) {
        accent = Color(attributes.accent)
        reply = Color(attributes.reply)
        attention = Color(attributes.attention)
    }

    func tint(_ phase: SendActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .sending, .pausing, .scheduled: accent
        case .waiting, .paused: attention
        case .done: reply
        }
    }
}

private extension Color {
    init(_ rgb: SendActivityAttributes.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private enum Phrase {
    /// A scheduled batch whose time has come: the activity went stale at it.
    static func isReady(_ state: SendActivityAttributes.ContentState, isStale: Bool) -> Bool {
        guard state.phase == .scheduled else { return false }
        return isStale || (state.startsAt.map { $0 <= .now } ?? true)
    }

    static func sendNowURL(_ state: SendActivityAttributes.ContentState) -> URL? {
        state.batchID.flatMap { URL(string: "aurora://queue/send/\($0)") }
    }
}

/// What's happening, in full, in the phase's colour: "Sending mail 4 of 11",
/// "Connection lost · retrying in 0:05", "Scheduled for 7:00 PM".
private struct Headline: View {
    let state: SendActivityAttributes.ContentState
    let style: Style
    let isStale: Bool

    var body: some View {
        Group {
            switch state.phase {
            case .sending:
                Text("Sending mail \(min(state.done + 1, state.total)) of \(state.total)")
            case .waiting:
                if let until = state.resumesAt, until > .now {
                    Text("\(state.note ?? "Waiting") · retrying in \(Text(timerInterval: Date.now...until, countsDown: true))")
                } else {
                    Text("\(state.note ?? "Waiting") · retrying now")
                }
            case .pausing:
                Text("Pausing after this mail")
            case .paused:
                Text(state.note.map { "Paused · \($0)" } ?? "Paused")
            case .done:
                Text(state.failed == 0 ? "All \(state.sent) sent" : "Finished · \(state.failed) failed")
            case .scheduled:
                if Phrase.isReady(state, isStale: isStale) {
                    Text("Ready to send")
                } else if let at = state.startsAt {
                    Text("Scheduled for \(at, style: .time)")
                } else {
                    Text("Scheduled")
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(style.tint(state.phase))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The batch's name, marked as one — "Not mailed yet" is the name of the
/// group it was picked by, not a status.
private struct BatchName: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "tray.full.fill")
        }
        .labelStyle(Tight())
        .font(.caption)
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
    }

    private struct Tight: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.caption2)
                configuration.title
            }
        }
    }
}

/// The Lock Screen and Notification Center: everything at once — what's
/// happening, the batch, how far it's got (sent, failed, to go), and who the
/// mail on its way is to, with their company and address.
private struct LockScreenView: View {
    let attributes: SendActivityAttributes
    let state: SendActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let style = Style(attributes)
        let ready = Phrase.isReady(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Tile(phase: state.phase, style: style, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Headline(state: state, style: style, isStale: isStale)
                        .font(.subheadline.weight(.semibold))
                    BatchName(title: state.title)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Tally(state: state, isStale: isStale)
            }

            if state.phase == .scheduled {
                ScheduledDetail(state: state, style: style, ready: ready, compact: false)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Meter(state: state, style: style)
                    Legend(state: state, style: style)
                }
                if state.recipient != nil {
                    Recipient(state: state, style: style, compact: false)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// A scheduled batch: how many mails, to where, and when — or, once it's
/// time, the button that sends it.
private struct ScheduledDetail: View {
    let state: SendActivityAttributes.ContentState
    let style: Style
    let ready: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.total) \(state.total == 1 ? "mail" : "mails")\(state.company.map { " · \($0)" } ?? "")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if ready {
                    Text("Its time has come")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                } else if let at = state.startsAt, at > .now {
                    Text("Goes in \(Text(timerInterval: Date.now...at, countsDown: true))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if ready, let url = Phrase.sendNowURL(state) {
                Link(destination: url) {
                    Label("Send Now", systemImage: "paperplane.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(style.accent, in: Capsule())
                }
            }
        }
        .padding(compact ? 0 : 10)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07))
            }
        }
    }
}

/// Sent, failed and to go, each with its colour in the meter.
private struct Legend: View {
    let state: SendActivityAttributes.ContentState
    let style: Style

    var body: some View {
        HStack(spacing: 12) {
            item("\(state.sent) sent", style.reply)
            if state.failed > 0 { item("\(state.failed) failed", style.attention) }
            if state.toGo > 0 { item("\(state.toGo) to go", .white.opacity(0.35)) }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(1)
    }

    private func item(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

/// Who the mail on its way is to — or, while the run waits, who's next —
/// with their company and address.
private struct Recipient: View {
    let state: SendActivityAttributes.ContentState
    let style: Style
    /// The Dynamic Island's two plain lines, rather than the Lock Screen's card.
    let compact: Bool

    var body: some View {
        let label = state.phase == .sending || state.phase == .pausing ? "To" : "Next"
        let who = [state.recipient, state.company].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 10) {
            if !compact {
                Image(systemName: label == "To" ? "envelope.fill" : "clock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.tint(state.phase))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.1), in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(label).foregroundStyle(.white.opacity(0.55))) \(who)")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let email = state.recipientEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 0 : 10)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07))
            }
        }
    }
}

/// The phase's glyph on a tinted rounded square.
private struct Tile: View {
    let phase: SendActivityAttributes.ContentState.Phase
    let style: Style
    let size: CGFloat

    var body: some View {
        Glyph(phase: phase, style: style, size: size * 0.42)
            .frame(width: size, height: size)
            .background(style.tint(phase).opacity(0.2), in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// The mark for what's happening.
private struct Glyph: View {
    let phase: SendActivityAttributes.ContentState.Phase
    let style: Style
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(style.tint(phase))
    }

    private var symbol: String {
        switch phase {
        case .sending: "paperplane.fill"
        case .waiting: "arrow.clockwise"
        case .pausing, .paused: "pause.fill"
        case .done: "checkmark"
        case .scheduled: "clock.fill"
        }
    }
}

/// "3/11" over "sent", serif figures as the app sets them — or, for a
/// scheduled batch, how many mails.
private struct Tally: View {
    let state: SendActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(state.phase == .scheduled ? "\(state.total)" : "\(state.done)/\(state.total)")
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(state.done)))
            Text(state.phase == .scheduled ? (state.total == 1 ? "mail" : "mails") : "done")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The compact island's right side: the count, a countdown while waiting,
/// or a scheduled batch's time.
private struct CompactTrailing: View {
    let state: SendActivityAttributes.ContentState
    let style: Style
    let ready: Bool

    var body: some View {
        Group {
            switch state.phase {
            case .waiting:
                if let until = state.resumesAt, until > .now {
                    Text(timerInterval: Date.now...until, countsDown: true)
                        .foregroundStyle(style.attention)
                        .frame(maxWidth: 44)
                } else {
                    count
                }
            case .scheduled:
                if ready {
                    Text("Send").foregroundStyle(style.accent)
                } else if let at = state.startsAt {
                    Text(at, style: .time).foregroundStyle(style.accent)
                }
            default:
                count
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
    }

    private var count: some View {
        Text("\(state.done)/\(state.total)")
            .fontDesign(.serif)
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(state.done)))
    }
}

/// Sent, then failed, along one bar.
private struct Meter: View {
    let state: SendActivityAttributes.ContentState
    let style: Style

    var body: some View {
        GeometryReader { proxy in
            let unit = state.total > 0 ? proxy.size.width / CGFloat(state.total) : 0
            HStack(spacing: 0) {
                Rectangle().fill(style.reply).frame(width: unit * CGFloat(state.sent))
                Rectangle().fill(style.attention).frame(width: unit * CGFloat(state.failed))
                Spacer(minLength: 0)
            }
            .background(Color.white.opacity(0.14))
            .clipShape(.capsule)
        }
        .frame(height: 6)
    }
}
