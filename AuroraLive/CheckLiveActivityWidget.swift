import ActivityKit
import SwiftUI
import WidgetKit

/// A reply check on the Lock Screen and in the Dynamic Island: which step it's
/// on and how far through the whole check, then what it found — "2 replies ·
/// 1 bounced". Tapping it opens Activity on the lane with news: Replied, or
/// Bounced when only bounces came.
struct CheckLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CheckActivityAttributes.self) { context in
            let style = Style(context.attributes)
            HStack(alignment: .top, spacing: 12) {
                Tile(state: context.state, style: style, size: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Summary(state: context.state, style: style, isStale: context.isStale)
                    if context.state.phase == .checking {
                        Meter(fraction: context.state.overall, style: style)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure(state: context.state)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(18)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(Self.url(context.state))
        } dynamicIsland: { context in
            let style = Style(context.attributes)
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Tile(state: state, style: style, size: 38)
                        .padding(.leading, 10)
                        .padding(.top, 8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Figure(state: state)
                        .font(.subheadline.weight(.semibold))
                        .padding(.trailing, 10)
                        .padding(.top, 8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.center) {
                    Summary(state: state, style: style, isStale: context.isStale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase == .checking {
                        Meter(fraction: state.overall, style: style)
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                }
            } compactLeading: {
                Glyph(state: state, style: style, size: 13)
                    .padding(.leading, 4)
            } compactTrailing: {
                CompactFigure(state: state, style: style)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52)
                    .padding(.trailing, 4)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                if state.phase == .checking {
                    Gauge(value: state.overall) {
                        Glyph(state: state, style: style, size: 10)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(style.accent)
                } else {
                    Glyph(state: state, style: style, size: 12)
                }
            }
            .contentMargins(.all, 14, for: .expanded)
            .widgetURL(Self.url(state))
            .keylineTint(style.accent)
        }
    }

    /// The lane with news: Replied, or Bounced when only bounces came.
    static func url(_ state: CheckActivityAttributes.ContentState) -> URL? {
        URL(string: state.replies == 0 && state.bounced > 0 ? "aurora://activity/bounced" : "aurora://activity/replied")
    }
}

/// The app's colours, as the activity carried them.
private struct Style {
    let accent: Color
    let reply: Color
    let attention: Color

    init(_ attributes: CheckActivityAttributes) {
        accent = Color(attributes.accent)
        reply = Color(attributes.reply)
        attention = Color(attributes.attention)
    }

    func tint(_ state: CheckActivityAttributes.ContentState) -> Color {
        switch state.phase {
        case .checking: accent
        case .stopped: attention
        case .done: state.bounced > 0 && state.replies == 0 ? attention : reply
        }
    }
}

private extension Color {
    init(_ rgb: SendActivityAttributes.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// What's happening, in the phase's colour, over the step and how far it's got.
private struct Summary: View {
    let state: CheckActivityAttributes.ContentState
    let style: Style
    /// Checking, but the app stopped saying so: suspended mid-check.
    var isStale = false

    private var isFrozen: Bool { isStale && state.phase == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isFrozen ? style.attention : style.tint(state))
            if let line {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var headline: String {
        if isFrozen { return "Check paused" }
        return switch state.phase {
        case .checking: "Checking for replies"
        case .done, .stopped: state.label
        }
    }

    private var line: String? {
        if isFrozen { return "Open Aurora to finish it" }
        return switch state.phase {
        case .checking:
            [state.steps > 0 && state.step > 0 ? "Step \(state.step) of \(state.steps)" : nil,
             state.label, state.detail].compactMap { $0 }.joined(separator: " · ")
        case .done: state.detail ?? "Your mail is checked"
        case .stopped: state.note
        }
    }
}

/// "40%" while checking; then the replies and bounces found, as figures.
private struct Figure: View {
    let state: CheckActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.phase == .checking {
                Text("\(Int((state.overall * 100).rounded()))%")
            } else if state.replies > 0 || state.bounced > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    if state.replies > 0 { Label("\(state.replies)", systemImage: "arrowshape.turn.up.left.fill") }
                    if state.bounced > 0 { Label("\(state.bounced)", systemImage: "exclamationmark.triangle.fill") }
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}

/// The compact island's trailing side: the percentage, or what was found.
private struct CompactFigure: View {
    let state: CheckActivityAttributes.ContentState
    let style: Style

    var body: some View {
        Group {
            switch state.phase {
            case .checking:
                Text("\(Int((state.overall * 100).rounded()))%")
            case .done, .stopped:
                if state.replies > 0 || state.bounced > 0 {
                    HStack(spacing: 4) {
                        if state.replies > 0 { Text("\(state.replies)").foregroundStyle(style.reply) }
                        if state.bounced > 0 { Text("\(state.bounced)").foregroundStyle(style.attention) }
                    }
                } else {
                    Image(systemName: "checkmark")
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(style.tint(state))
        .lineLimit(1)
    }
}

private struct Tile: View {
    let state: CheckActivityAttributes.ContentState
    let style: Style
    let size: CGFloat

    var body: some View {
        Glyph(state: state, style: style, size: size * 0.42)
            .frame(width: size, height: size)
            .background(style.tint(state).opacity(0.2), in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

private struct Glyph: View {
    let state: CheckActivityAttributes.ContentState
    let style: Style
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(style.tint(state))
            .symbolEffect(.pulse, options: .repeating, isActive: state.phase == .checking)
    }

    private var symbol: String {
        switch state.phase {
        case .checking: "envelope.badge"
        case .stopped: "pause.fill"
        case .done: state.replies > 0 ? "envelope.open.fill" : state.bounced > 0 ? "exclamationmark.triangle.fill" : "checkmark"
        }
    }
}

/// How far through the whole check.
private struct Meter: View {
    let fraction: Double
    let style: Style

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(style.accent)
                .frame(width: proxy.size.width * min(1, max(0, fraction)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.14))
                .clipShape(.capsule)
        }
        .frame(height: 6)
    }
}
