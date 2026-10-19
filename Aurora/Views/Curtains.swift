import SwiftUI

// The app's curtains (see `Curtain` in Support/Cinema.swift): one per big
// moment, each a figure acting in the middle of the same grainy ground.

// MARK: - Queued

/// The moment a batch is handed to the queue: envelopes drop one by one onto a
/// stack while its count ticks up, and "Queued" rises in under it.
@MainActor
enum QueuedCurtain {
    /// Announce `count` mails queued. With `scheduledFor`, it names the time
    /// they'll go instead.
    static func show(count: Int, scheduledFor: Date? = nil) {
        guard count > 0 else { return }
        let what = count == 1 ? "1 mail" : "\(count) mails"
        Curtain.show(Curtain.Cue(
            title: scheduledFor == nil ? "Queued" : "Scheduled",
            subtitle: subtitle(count: count, scheduledFor: scheduledFor),
            announcement: scheduledFor == nil ? "Queued \(what)" : "Scheduled \(what)",
            figureTime: Double(EnvelopeStack.drops(count)) * 0.25 + 0.05
        )) { beat in
            EnvelopeStack(count: count, beat: beat)
        }
    }

    private static func subtitle(count: Int, scheduledFor: Date?) -> String {
        if let scheduledFor {
            let when = scheduledFor.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "\(count == 1 ? "1 mail goes" : "\(count) mails go") out \(when)"
        }
        return count == 1 ? "Going out from your Gmail now" : "\(count) mails, going out one after another"
    }
}

private struct EnvelopeStack: View {
    let count: Int
    let beat: CurtainBeat

    /// Envelopes on the stack so far.
    @State private var landed = 0
    /// The count on the stack's badge.
    @State private var shown = 0

    /// At most three envelopes drop; the badge carries the rest.
    static func drops(_ count: Int) -> Int { min(count, 3) }
    private var drops: Int { Self.drops(count) }

    /// Each envelope's tilt as it falls, and once it's on the stack.
    private static let fallTilt: [Double] = [-24, 19, -11]
    private static let restTilt: [Double] = [-5, 4, -1.5]
    /// How far each envelope sits above the one under it.
    private static let step: CGFloat = 16

    var body: some View {
        ZStack {
            CinemaRings(isOut: beat >= .playing)

            ZStack {
                ForEach(0..<drops, id: \.self) { index in
                    let down = landed > index
                    EnvelopeMark(depth: Double(drops - 1 - index) * 0.18)
                        .rotationEffect(.degrees(down ? Self.restTilt[index] : Self.fallTilt[index]))
                        .offset(y: down ? -CGFloat(index) * Self.step : -900)
                }
            }
            // The stack gives a little under each envelope that lands on it.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: landed) { content, squash in
                content.scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.14)
                CubicKeyframe(0.93, duration: 0.07)
                SpringKeyframe(1, duration: 0.35, spring: .bouncy)
            }
            .overlay(alignment: .topTrailing) { badge }
        }
        .frame(width: 160, height: 104 + Self.step * 2)
        .task(id: beat) { await act() }
    }

    private var badge: some View {
        Text("\(shown)")
            .font(.system(.title2, design: .serif).weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(shown)))
            .foregroundStyle(Color.paper)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 52, height: 52)
            .background {
                Circle()
                    .fill(Color.ink)
                    .shadow(color: .black.opacity(0.4), radius: 0, x: 4, y: 5)
            }
            .scaleEffect(shown > 0 ? 1 : 0.2)
            .opacity(shown > 0 ? 1 : 0)
            .offset(x: 22, y: -26 - CGFloat(max(landed - 1, 0)) * Self.step)
    }

    private func act() async {
        switch beat {
        case .washing, .leaving:
            return
        case .titled:
            // Reduce Motion goes straight here: the stack is simply at rest.
            guard landed < drops else { return }
            landed = drops
            shown = count
        case .playing:
            for index in 0..<drops {
                withAnimation(.spring(duration: 0.45, bounce: 0.36)) { landed = index + 1 }
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled else { return }
                Haptics.tap(0.45 + CGFloat(index) * 0.15)
                withAnimation(.snappy(duration: 0.3)) { shown = index == drops - 1 ? count : index + 1 }
                try? await Task.sleep(for: .seconds(0.1))
                guard !Task.isCancelled else { return }
            }
        }
    }
}

/// A flat envelope in the accent, printed: `depth` darkens the ones
/// further down the stack.
private struct EnvelopeMark: View {
    let depth: Double

    var body: some View {
        Flap()
            .stroke(Color.paper.opacity(0.85),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .padding(16)
            .frame(width: 150, height: 104)
            .printed(cornerRadius: 13, fill: Color.clay.mix(with: .black, by: depth))
    }

    /// The envelope's flap: a V from the top corners down to the middle.
    private struct Flap: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.62))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
        }
    }
}

// MARK: - Written

/// A change from writing help, or from Writing Tools, going into the text: a
/// printed page whose old lines are wiped while new ones are inked across it in
/// Apple Intelligence's colours, then sparkles stamp it.
@MainActor
enum WrittenCurtain {
    /// `rewrote`: there was text before (it's "Rewritten", not "Written").
    /// `landing`: where it went, and what keeps it.
    static func show(rewrote: Bool, landing: String) {
        let title = rewrote ? "Rewritten" : "Written"
        Curtain.show(Curtain.Cue(title: title, subtitle: landing, announcement: "\(title). \(landing)",
                                 figureTime: 0.75, hold: 0.85)) { beat in
            InkedPage(rewrote: rewrote, beat: beat)
        }
    }
}

private struct InkedPage: View {
    let rewrote: Bool
    let beat: CurtainBeat

    /// New lines inked so far.
    @State private var inked = 0

    /// Each line's length, as a share of the page's width.
    private static let lines: [CGFloat] = [0.92, 0.74, 0.86, 0.52]
    private static let width: CGFloat = 196

    var body: some View {
        ZStack {
            CinemaRings(isOut: beat >= .playing)

            VStack(alignment: .leading, spacing: 13) {
                ForEach(Self.lines.indices, id: \.self) { index in
                    line(index)
                }
            }
            .padding(22)
            .frame(width: Self.width, alignment: .leading)
            .printed(cornerRadius: 14, fill: Color.paperRaised)
            .rotationEffect(.degrees(beat >= .playing ? -3 : -9))
            .scaleEffect(beat >= .playing ? 1 : 0.86)
            .animation(.spring(duration: 0.6, bounce: 0.3), value: beat >= .playing)
            .overlay(alignment: .topTrailing) { stamp }
        }
        .frame(width: Self.width, height: 150)
        .task(id: beat) { await act() }
    }

    private func line(_ index: Int) -> some View {
        let length = (Self.width - 44) * Self.lines[index]
        let isInked = inked > index
        return ZStack(alignment: .leading) {
            // The old line, wiped from the left as the new one is inked over it.
            if rewrote {
                Capsule()
                    .fill(Color.inkFaint.opacity(0.55))
                    .frame(width: length, height: 7)
                    .scaleEffect(x: isInked ? 0.001 : 1, anchor: .trailing)
                    .opacity(isInked ? 0 : 1)
            }
            Capsule()
                .fill(AIStyle.linear)
                .frame(width: length, height: 7)
                .scaleEffect(x: isInked ? 1 : 0.001, anchor: .leading)
        }
        .frame(height: 7)
    }

    /// Sparkles pressed onto the page's corner once it's written, with a burst.
    @ViewBuilder
    private var stamp: some View {
        if beat >= .titled {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AIStyle.linear)
                .padding(12)
                .printed(cornerRadius: 28, fill: Color.paper)
                // The burst spreads from the stamp without taking up room.
                .background { AISparkleBurst(count: 10).frame(width: 180, height: 180) }
                .offset(x: 28, y: -28)
                .transition(.scale(scale: 2.2).combined(with: .opacity))
        }
    }

    private func act() async {
        switch beat {
        case .washing, .leaving:
            return
        case .titled:
            guard inked < Self.lines.count else { return }
            inked = Self.lines.count
        case .playing:
            for index in Self.lines.indices {
                withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.3)) { inked = index + 1 }
                Haptics.tap(0.35 + CGFloat(index) * 0.1)
                try? await Task.sleep(for: .seconds(0.13))
                guard !Task.isCancelled else { return }
            }
        }
    }
}
