import SwiftUI
import UIKit

/// The moment a batch leaves: paper planes lift off the bottom of the screen,
/// climb along a glowing curve — the outreach chart, drawn by the send itself —
/// loop once, and streak away over the top edge, while a capsule says what
/// went out.
///
/// It plays in a window of its own above everything, with touches passing
/// straight through, because the send closes the sheet it was started from:
/// drawn inside the app it would be dragged down with that sheet, or hidden
/// beneath it. Up here it flies across the sheet as it leaves.
///
/// Under Reduce Motion only the capsule appears.
@MainActor
enum SendFlight {
    private static var window: UIWindow?
    private static var generation = 0

    /// Fly `count` mails off. With `scheduledFor`, the capsule names the time
    /// they'll go instead.
    static func launch(count: Int, scheduledFor: Date? = nil) {
        guard count > 0,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }

        generation += 1
        let run = generation
        let host = UIHostingController(rootView: SendFlightView(count: count, scheduledFor: scheduledFor))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.rootViewController = host
        window.isHidden = false
        Self.window = window

        Task {
            try? await Task.sleep(for: SendFlightView.duration)
            // A second send started meanwhile owns the window now.
            guard run == generation else { return }
            Self.window?.isHidden = true
            Self.window = nil
        }
    }
}

private struct SendFlightView: View {
    let count: Int
    let scheduledFor: Date?

    static let duration: Duration = .milliseconds(2_100)
    private static let seconds = 2.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var capsuleShown = false

    /// One plane per mail, up to three — enough to read as "several".
    private var planes: Int { min(count, 3) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let t = min(timeline.date.timeIntervalSince(start) / Self.seconds, 1)
                        Canvas { context, canvasSize in
                            draw(context: context, size: canvasSize, t: t)
                        }
                    }
                }
                capsule
                    .scaleEffect(capsuleShown ? 1 : 0.6)
                    .opacity(capsuleShown ? 1 : 0)
                    .position(x: size.width / 2, y: size.height * 0.42)
            }
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 520))
            withAnimation(Theme.Motion.pop) { capsuleShown = true }
            try? await Task.sleep(for: .milliseconds(1_050))
            withAnimation(.smooth(duration: 0.4)) { capsuleShown = false }
        }
        .accessibilityHidden(true)
    }

    private var capsule: some View {
        let title: String = scheduledFor == nil
            ? (count == 1 ? "Mail on its way" : "\(count) mails on their way")
            : "Scheduled \(scheduledFor!.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        return HStack(spacing: 8) {
            Image(systemName: scheduledFor == nil ? "paperplane.fill" : "clock.fill")
                .foregroundStyle(.clay)
                .symbolEffect(.bounce.up, value: capsuleShown)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(Color.clay.opacity(0.14)), in: .capsule)
    }

    // MARK: Flight

    /// Where a plane is `s` (0…1) of the way along its route, for a screen of
    /// `size`. Off the bottom, a rising curve with one loop at its crest, then
    /// a straight streak off the top-right corner.
    private func route(_ s: Double, lane: Double, size: CGSize) -> CGPoint {
        let w = Double(size.width), h = Double(size.height)
        let startX = w * (0.5 + 0.06 * lane), startY = h + 30
        let crestX = w * (0.42 + 0.05 * lane), crestY = h * (0.52 - 0.03 * lane)
        if s < 0.45 {
            // The climb: an ease-out arc from the send button to the crest.
            let p = s / 0.45
            let e = 1 - pow(1 - p, 2)
            let x = startX + (crestX - startX) * e - 40 * sin(p * .pi) * (1 + 0.2 * lane)
            let y = startY + (crestY - startY) * e
            return CGPoint(x: x, y: y)
        } else if s < 0.7 {
            // The loop.
            let p = (s - 0.45) / 0.25
            let angle = .pi / 2 + p * 2 * .pi
            let r = 46.0 + 6 * lane
            return CGPoint(x: crestX + r * cos(angle) * -1, y: crestY - r + r * sin(angle))
        } else {
            // The streak away, accelerating.
            let p = (s - 0.7) / 0.3
            let e = p * p
            return CGPoint(x: crestX + (w + 80 - crestX) * e, y: crestY + (-120 - crestY) * e)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize, t: Double) {
        let accent = Color.clay, reply = Color.olive
        for index in 0..<planes {
            let lane = Double(index) - Double(planes - 1) / 2
            // Each plane leaves a beat after the one before it.
            let s = min(max((t - Double(index) * 0.06) / 0.88, 0), 1)
            guard s > 0, s < 1 else { continue }

            // The trail: the last stretch of the route, fading toward its tail —
            // the chart the send draws as it goes.
            var trail = Path()
            let tail = max(0, s - 0.28)
            let steps = 28
            for step in 0...steps {
                let u = tail + (s - tail) * Double(step) / Double(steps)
                let point = route(u, lane: lane, size: size)
                if step == 0 { trail.move(to: point) } else { trail.addLine(to: point) }
            }
            let head = route(s, lane: lane, size: size)
            let back = route(tail, lane: lane, size: size)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [accent.opacity(0), accent.opacity(0.85)]), startPoint: back, endPoint: head)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.opacity = 0.5
                layer.stroke(trail, with: shading, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            context.stroke(trail, with: shading, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            // Sparks shed along the way.
            for spark in 0..<3 {
                let u = max(0, s - Double(spark) * 0.045)
                let point = route(u, lane: lane, size: size)
                let drift = CGFloat(spark) * 4
                let r = CGFloat(2.2 - 0.35 * Double(spark))
                context.fill(Path(ellipseIn: CGRect(x: point.x - r + drift, y: point.y - r + drift, width: r * 2, height: r * 2)),
                             with: .color((spark.isMultiple(of: 2) ? accent : reply).opacity(0.45 - 0.1 * Double(spark))))
            }

            // The plane, pointed along its path.
            let ahead = route(min(1, s + 0.01), lane: lane, size: size)
            let heading = atan2(ahead.y - head.y, ahead.x - head.x)
            let scale = s > 0.7 ? 1 - 0.5 * (s - 0.7) / 0.3 : 1
            var plane = context
            plane.translateBy(x: head.x, y: head.y)
            // The glyph points up and to the right (45°) at rest.
            plane.rotate(by: .radians(heading + .pi / 4))
            plane.scaleBy(x: scale, y: scale)
            var glyph = plane.resolve(Image(systemName: "paperplane.fill"))
            glyph.shading = .color(.white)
            var halo = plane
            halo.addFilter(.blur(radius: 8))
            halo.fill(Path(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24)), with: .color(accent.opacity(0.3)))
            plane.draw(glyph, in: CGRect(x: -10, y: -10, width: 20, height: 20))
        }
    }
}
