import ActivityKit
import SwiftUI
import WidgetKit

/// Writing help waiting on the Aurora Writer shortcut, in the Dynamic Island and
/// on the Lock Screen: what was asked and how long it's been writing. Tapping it
/// opens Aurora.
struct WritingLiveActivityWidget: Widget {
    static let openURL = URL(string: "aurora://writing")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WritingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Tile(accent: Color(context.attributes.accent), size: 40)
                Summary(state: context.state, accent: Color(context.attributes.accent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Elapsed(since: context.state.startedAt)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(18)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(Self.openURL)
        } dynamicIsland: { context in
            let accent = Color(context.attributes.accent)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Tile(accent: accent, size: 38)
                        .padding(.leading, 10)
                        .padding(.top, 8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: context.state.startedAt)
                        .font(.subheadline.weight(.semibold))
                        .padding(.trailing, 10)
                        .padding(.top, 8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.center) {
                    Summary(state: context.state, accent: accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("The answer comes back to Aurora for you to review.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            } compactLeading: {
                Sparkles(accent: accent, size: 13)
                    .padding(.leading, 4)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } compactTrailing: {
                Elapsed(since: context.state.startedAt)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 44)
                    .padding(.trailing, 4)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } minimal: {
                Sparkles(accent: accent, size: 12)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            .contentMargins(.all, 14, for: .expanded)
            .widgetURL(Self.openURL)
            .keylineTint(accent)
        }
    }
}

private extension Color {
    init(_ rgb: SendActivityAttributes.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// "Writing with Apple Intelligence" over what was asked.
private struct Summary: View {
    let state: WritingActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Writing with Apple Intelligence")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            Text(state.request)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
        .lineLimit(1)
    }
}

private struct Sparkles: View {
    let accent: Color
    var size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(accent)
            .symbolEffect(.pulse, options: .repeating)
    }
}

private struct Tile: View {
    let accent: Color
    let size: CGFloat

    var body: some View {
        Sparkles(accent: accent, size: size * 0.42)
            .frame(width: size, height: size)
            .background(accent.opacity(0.2), in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// How long it's been writing, counting up: "0:12".
private struct Elapsed: View {
    let since: Date

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.white)
            .lineLimit(1)
    }
}
