import ActivityKit
import SwiftUI
import WidgetKit

/// The mail queue on the Lock Screen and in the Dynamic Island: what's
/// sending, how far it's got, and — when Gmail has asked the run to slow
/// down — a countdown to when it carries on. Tapping it opens Activity's
/// In Progress lane.
struct SendLiveActivityWidget: Widget {
    static let openURL = URL(string: "aurora://activity/in-progress")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SendActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.openURL)
        } dynamicIsland: { context in
            let style = Style(context.attributes)
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Glyph(phase: state.phase, mark: context.attributes.mark, style: style)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Count(state: state, style: style)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // What's happening over the batch's name, each on its own
                    // line, so a long name never pushes the count.
                    VStack(spacing: 1) {
                        Text(Headline.phase(state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(style.tint(state.phase))
                        Text(state.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Meter(state: state, style: style)
                        Detail(state: state, style: style)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Glyph(phase: state.phase, mark: context.attributes.mark, style: style, size: 14)
            } compactTrailing: {
                if state.phase == .waiting, let until = state.resumesAt, until > .now {
                    Text(timerInterval: Date.now...until, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(style.attention)
                        .frame(maxWidth: 44)
                } else {
                    Count(state: state, style: style)
                }
            } minimal: {
                Gauge(value: state.fraction) {
                    Glyph(phase: state.phase, mark: context.attributes.mark, style: style, size: 10)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(style.accent)
            }
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
        case .sending, .pausing: accent
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

private enum Headline {
    static func phase(_ state: SendActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .sending: "Sending"
        case .waiting: "Waiting on Gmail"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .done: state.failed == 0 ? "All sent" : "Done"
        }
    }

    static func title(_ state: SendActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .sending: "Sending · \(state.title)"
        case .waiting: "Waiting on Gmail · \(state.title)"
        case .pausing: "Pausing · \(state.title)"
        case .paused: "Paused · \(state.title)"
        case .done: state.failed == 0 ? "All sent · \(state.title)" : "Done · \(state.title)"
        }
    }
}

private struct LockScreenView: View {
    let attributes: SendActivityAttributes
    let state: SendActivityAttributes.ContentState

    var body: some View {
        let style = Style(attributes)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Glyph(phase: state.phase, mark: attributes.mark, style: style, size: 18)
                    .frame(width: 38, height: 38)
                    .background(style.tint(state.phase).opacity(0.2), in: .rect(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Headline.title(state))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Detail(state: state, style: style)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Count(state: state, style: style)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            Meter(state: state, style: style)
        }
        .padding(16)
    }
}

/// The mark for what's happening: the theme's own while sending.
private struct Glyph: View {
    let phase: SendActivityAttributes.ContentState.Phase
    let mark: String
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
        case .waiting: "hourglass"
        case .pausing, .paused: "pause.fill"
        case .done: "checkmark"
        }
    }
}

/// "3/11", serif figures as the app sets them.
private struct Count: View {
    let state: SendActivityAttributes.ContentState
    let style: Style

    var body: some View {
        Text("\(state.done)/\(state.total)")
            .fontDesign(.serif)
            .monospacedDigit()
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

/// The second line: who it's going to, the countdown, or why it stopped.
private struct Detail: View {
    let state: SendActivityAttributes.ContentState
    let style: Style

    var body: some View {
        Group {
            switch state.phase {
            case .sending:
                Text(state.recipient.map { "To \($0)" } ?? "\(state.total - state.done) to go")
            case .waiting:
                if let until = state.resumesAt, until > .now {
                    Text("Gmail asked to slow down · trying again in \(Text(timerInterval: Date.now...until, countsDown: true))")
                } else {
                    Text("Gmail asked to slow down · trying again")
                }
            case .pausing:
                Text("Finishing the mail on its way")
            case .paused:
                if let until = state.resumesAt {
                    Text("Carries on at \(until, style: .time)")
                } else {
                    Text(state.note ?? "\(state.total - state.done) to go")
                }
            case .done:
                Text(state.failed == 0 ? "\(state.sent) sent" : "\(state.sent) sent · \(state.failed) failed")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.72))
        .lineLimit(1)
    }
}
