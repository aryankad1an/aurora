import SwiftUI
import UIKit

/// The moment a batch leaves. A glass capsule drops out from under the Dynamic
/// Island; paper planes lift off the bottom of the screen on tapering ribbons,
/// loop once, and dock in it. As the first one lands the capsule opens to say
/// what went out and its plane turns into a tick, then it tucks back up where
/// it came from.
///
/// It plays in a window of its own above everything, with touches passing
/// straight through, because the send closes the sheet it was started from:
/// drawn inside the app it would be dragged down with that sheet, or hidden
/// beneath it. Up here it flies across the sheet as it leaves.
///
/// Under Reduce Motion only the capsule appears, fading in and out in place.
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

    /// How long the window stays up: every plane docked and the capsule gone.
    static let duration: Duration = .milliseconds(3_000)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var iconSide = 30
    @State private var start = Date.now
    @State private var stage = Stage.hidden
    @State private var landings = 0
    /// The docked capsule's frame in window space, before it opens — where the
    /// planes aim.
    @State private var dock: CGRect?
    /// The title's width, so the closed row can be shifted to centre its icon.
    @State private var titleWidth: CGFloat = 0

    private enum Stage { case hidden, docking, open, gone }

    /// One plane per mail, up to three — enough to read as "several".
    private var planes: Int { min(count, 3) }

    private var isShown: Bool { stage == .docking || stage == .open }
    private var isOpen: Bool { stage == .open || stage == .gone }

    var body: some View {
        ZStack(alignment: .top) {
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    Canvas { context, size in
                        guard let dock else { return }
                        draw(context, size: size, elapsed: elapsed, dock: dock)
                    }
                }
                .ignoresSafeArea()
            }
            capsule
                // Each plane landing knocks the capsule, like a dart into a board.
                .keyframeAnimator(initialValue: 1.0, trigger: landings) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        CubicKeyframe(1.08, duration: 0.08)
                        SpringKeyframe(1, duration: 0.42, spring: .bouncy)
                    }
                }
                // Hidden, it's a speck tucked up under the Dynamic Island.
                .scaleEffect(isShown || reduceMotion ? 1 : 0.3)
                .offset(y: isShown || reduceMotion ? 0 : -46)
                .opacity(isShown ? 1 : 0)
                .padding(.top, 2)
                .padding(.horizontal, 16)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .task { await play() }
        .accessibilityHidden(true)
    }

    private var title: String {
        if let scheduledFor {
            return "Scheduled \(scheduledFor.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return count == 1 ? "Mail on its way" : "\(count) mails on their way"
    }

    private var pill: Pill { Pill(openness: isOpen ? 1 : 0, closed: iconSide + 16) }

    private func glyph(_ name: String, shown: Bool) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            // Both glyphs stay mounted and cross-fade. A symbol replace, or an
            // inserted view, is placed at its own end point and so drifted
            // apart from the circle while the bar was opening.
            ZStack {
                Circle().fill(Color.clay)
                glyph("paperplane.fill", shown: !isOpen)
                glyph(scheduledFor == nil ? "checkmark" : "clock.fill", shown: isOpen)
            }
            .frame(width: iconSide, height: iconSide)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                // Measured only until it opens; then the icon slides aside for
                // the title, and the planes still in flight keep their aim.
                if !isOpen { dock = $0.insetBy(dx: -8, dy: -8) }
            }
            // Always laid out, so it travels with the icon; an inserted title
            // sat at its end point while the icon slid across it.
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ink)
                .lineLimit(2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                .opacity(isOpen ? 1 : 0)
        }
        // Closed, the row is shifted so its icon sits in the middle.
        .offset(x: isOpen ? 0 : (titleWidth + 10) / 2)
        .padding(8)
        // Laid out at the bar's full width throughout; only the drawn pill
        // grows, from the middle. Animating the layout width instead opened it
        // out to one side first, since its size and position don't move in step.
        .frame(maxWidth: .infinity)
        // Open, it spans the top bar like a system banner. Solid, not glass:
        // narrower or see-through, it sat beside the bar's own buttons and the
        // two read as jammed together rather than one laid over the other.
        .background {
            pill
                .fill(Color.paperRaised)
                .overlay(pill.fill(Color.clay.opacity(0.1)))
                .overlay(pill.strokeBorder(Color.clay.opacity(0.35), lineWidth: 0.75))
        }
        // Clipped to the pill, which wipes the title in as it widens.
        .clipShape(pill)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { stage = .open }
            await sleep(until: 1.9)
            withAnimation(.easeIn(duration: 0.3)) { stage = .gone }
            return
        }
        await sleep(until: 0.08)
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { stage = .docking }
        for index in 0..<planes {
            await sleep(until: Flight.arrival(index))
            if index == 0 {
                Haptics.lift(0.5)
                withAnimation(Theme.Motion.liquid) { stage = .open }
            }
            landings += 1
        }
        await sleep(until: Flight.arrival(0) + 1.15)
        withAnimation(.spring(duration: 0.45, bounce: 0)) { stage = .gone }
    }

    private func sleep(until moment: Double) async {
        let wait = moment - Date.now.timeIntervalSince(start)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    // MARK: Flight

    private enum Flight {
        /// Seconds one plane takes from the bottom edge to the dock.
        static let leg = 1.25
        /// Each plane leaves this long after the one before it.
        static let stagger = 0.12
        /// Points of ribbon behind each plane.
        static let trail = 150.0
        /// How far along its route a plane is at `t` (0…1) of its leg: fast off
        /// the button, quickest through the loop, easing in to dock. The ends
        /// keep some speed so it never sits still.
        static func ease(_ t: Double) -> Double { 0.35 * t + 0.65 * t * t * (3 - 2 * t) }
        /// The ease's slope at the dock, so the ribbon is reeled in at the speed
        /// the plane arrived.
        static let endSpeed = 0.35

        static func arrival(_ index: Int) -> Double { Double(index) * stagger + leg }
    }

    private func draw(_ context: GraphicsContext, size: CGSize, elapsed: Double, dock: CGRect) {
        let accent = Color.clay, reply = Color.olive

        let target = CGPoint(x: dock.midX, y: dock.midY)

        // A ring rippling out from where each plane docks.
        for index in 0..<planes {
            let age = (elapsed - Flight.arrival(index)) / 0.55
            guard age > 0, age < 1 else { continue }
            let radius = dock.height / 2 + 4 + 26 * (1 - pow(1 - age, 3))
            let ring = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: ring),
                           with: .color(accent.opacity(0.45 * (1 - age))), lineWidth: 0.5 + 1.2 * (1 - age))
        }

        for index in 0..<planes {
            let lane = Double(index) - Double(planes - 1) / 2
            let t = (elapsed - Double(index) * Flight.stagger) / Flight.leg
            guard t > 0 else { continue }
            let route = Route(lane: lane, size: size, dock: target)
            // Past the dock the head keeps going, virtually, so the ribbon is
            // reeled into the capsule rather than snapping off.
            let head = t <= 1 ? route.length * Flight.ease(t)
                              : route.length * (1 + Flight.endSpeed * (t - 1))
            guard head - Flight.trail < route.length else { continue }

            drawRibbon(context, route: route, head: head, color: accent)
            drawDust(context, route: route, head: head, colors: (accent, reply))
            if head < route.length {
                drawPlane(context, route: route, head: head, color: accent)
            }
        }
    }

    /// The trail: a thread at its tail swelling toward the plane, built from
    /// strokes stacked toward the head so it tapers without seams.
    private func drawRibbon(_ context: GraphicsContext, route: Route, head: Double, color: Color) {
        let end = min(head, route.length)
        let start = max(0, head - Flight.trail)
        guard end - start > 1 else { return }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.opacity = 0.4
            layer.stroke(route.path(from: start, to: end),
                         with: .linearGradient(Gradient(colors: [color.opacity(0), color]),
                                               startPoint: route.point(at: start), endPoint: route.point(at: end)),
                         style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        let layers = 5
        for layer in 1...layers {
            let reach = Double(layer) / Double(layers)
            let from = max(start, head - Flight.trail * reach)
            guard end - from > 0.5 else { continue }
            context.stroke(route.path(from: from, to: end), with: .color(color.opacity(0.22)),
                           style: StrokeStyle(lineWidth: 0.9 + 2 * (1 - reach), lineCap: .butt, lineJoin: .round))
        }
    }

    /// Specks shed at even spacing along the route, drifting off it and sinking
    /// a little as they fade.
    private func drawDust(_ context: GraphicsContext, route: Route, head: Double, colors: (Color, Color)) {
        let spacing = 16.0, life = 120.0
        var mark = (max(0, head - life) / spacing).rounded(.up) * spacing
        while mark <= min(head, route.length) {
            defer { mark += spacing }
            guard mark > 0 else { continue }
            let age = (head - mark) / life
            let seed = Int(mark / spacing)
            let side: Double = seed.isMultiple(of: 2) ? 1 : -1
            let jitter = Double((seed * 7_919) % 13) / 13
            let normal = route.heading(at: mark) + .pi / 2
            let drift = side * (4 + 10 * jitter) * age
            let origin = route.point(at: mark)
            let point = CGPoint(x: origin.x + cos(normal) * drift,
                                y: origin.y + sin(normal) * drift + 14 * age * age)
            let r = 0.3 + 1.6 * (1 - age)
            let color = seed.isMultiple(of: 3) ? colors.1 : colors.0
            context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                         with: .color(color.opacity(0.5 * (1 - age))))
        }
    }

    /// The plane, pointed along its path, shrinking and fading into the dock.
    private func drawPlane(_ context: GraphicsContext, route: Route, head: Double, color: Color) {
        let point = route.point(at: head)
        let landing = min(max(1 - (route.length - head) / 90, 0), 1)
        let scale = 1 - 0.6 * landing
        var plane = context
        plane.opacity = 1 - landing * landing
        plane.translateBy(x: point.x, y: point.y)
        // The glyph points up and to the right (45°) at rest.
        plane.rotate(by: .radians(route.heading(at: head) + .pi / 4))
        plane.scaleBy(x: scale, y: scale)
        var glyph = plane.resolve(Image(systemName: "paperplane.fill"))
        glyph.shading = .color(.white)
        var halo = plane
        halo.addFilter(.blur(radius: 8))
        halo.fill(Path(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24)), with: .color(color.opacity(0.3)))
        plane.draw(glyph, in: CGRect(x: -10, y: -10, width: 20, height: 20))
    }
}

/// One plane's route, measured by distance so it can be flown at any speed
/// without corners or stops: up from below the screen, once round a loop, then
/// up into the capsule. A centripetal Catmull-Rom spline through a handful of
/// knots, sampled into a polyline.
/// A capsule centred in its rect that grows from a `closed`-point circle
/// (`openness` 0) to fill the rect (1). Animating `openness` keeps it centred
/// at every step, where an animated frame drifts to one side.
private nonisolated struct Pill: InsettableShape {
    var openness: CGFloat
    var closed: CGFloat
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = closed + (rect.width - closed) * openness
        let height = closed + (rect.height - closed) * openness
        let box = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
            .insetBy(dx: inset, dy: inset)
        return Path(roundedRect: box, cornerRadius: min(box.width, box.height) / 2)
    }

    func inset(by amount: CGFloat) -> Pill {
        var pill = self
        pill.inset += amount
        return pill
    }
}

private struct Route {
    private let points: [CGPoint]
    /// Distance along the route to each point.
    private let marks: [Double]
    var length: Double { marks.last ?? 0 }

    init(lane: Double, size: CGSize, dock: CGPoint) {
        let w = Double(size.width), h = Double(size.height)
        // The loop sits just left of the line the plane climbs, so it rises
        // straight into it and leaves straight out of it.
        let x = Double(dock.x) + 14 * lane
        let r = 50 + 6 * lane
        let cy = h * 0.55 + 10 * lane
        let cx = x - r
        var knots = [CGPoint(x: w * 0.62 + 14 * lane, y: h + 40),
                     CGPoint(x: x + 10, y: h * 0.8)]
        for step in 0...8 {
            let angle = Double(step) * .pi / 4
            knots.append(CGPoint(x: cx + r * cos(angle), y: cy - r * sin(angle)))
        }
        knots.append(CGPoint(x: x, y: (cy + Double(dock.y)) / 2))
        knots.append(CGPoint(x: Double(dock.x) + 5 * lane, y: Double(dock.y) + 50))
        knots.append(dock)

        points = Self.spline(through: knots, samples: 14)
        var marks = [0.0]
        for index in 1..<points.count {
            marks.append(marks[index - 1] + hypot(points[index].x - points[index - 1].x,
                                                  points[index].y - points[index - 1].y))
        }
        self.marks = marks
    }

    func point(at distance: Double) -> CGPoint {
        let d = min(max(distance, 0), length)
        var lo = 0, hi = marks.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if marks[mid] < d { lo = mid } else { hi = mid }
        }
        let span = marks[hi] - marks[lo]
        return Self.mix(points[lo], points[hi], span > 0 ? (d - marks[lo]) / span : 0)
    }

    /// The direction of travel at `distance`, in radians.
    func heading(at distance: Double) -> Double {
        let a = point(at: distance - 3), b = point(at: distance + 3)
        return atan2(b.y - a.y, b.x - a.x)
    }

    func path(from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, Int((end - start) / 6))
        for step in 0...steps {
            let point = point(at: start + (end - start) * Double(step) / Double(steps))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Centripetal Catmull-Rom (Barry–Goldman): passes through every knot and,
    /// unlike the uniform kind, never cusps or overshoots where knots bunch up.
    private static func spline(through knots: [CGPoint], samples: Int) -> [CGPoint] {
        guard knots.count > 1 else { return knots }
        let first = knots[0], second = knots[1]
        let last = knots[knots.count - 1], beforeLast = knots[knots.count - 2]
        let padded = [CGPoint(x: 2 * first.x - second.x, y: 2 * first.y - second.y)]
            + knots
            + [CGPoint(x: 2 * last.x - beforeLast.x, y: 2 * last.y - beforeLast.y)]
        func gap(_ a: CGPoint, _ b: CGPoint) -> Double {
            max(sqrt(hypot(b.x - a.x, b.y - a.y)), 1e-4)
        }

        var out = [first]
        for index in 1..<(padded.count - 2) {
            let p0 = padded[index - 1], p1 = padded[index], p2 = padded[index + 1], p3 = padded[index + 2]
            let t1 = gap(p0, p1), t2 = t1 + gap(p1, p2), t3 = t2 + gap(p2, p3)
            for sample in 1...samples {
                let t = t1 + (t2 - t1) * Double(sample) / Double(samples)
                let a1 = mix(p0, p1, t / t1)
                let a2 = mix(p1, p2, (t - t1) / (t2 - t1))
                let a3 = mix(p2, p3, (t - t2) / (t3 - t2))
                let b1 = mix(a1, a2, t / t2)
                let b2 = mix(a2, a3, (t - t1) / (t3 - t1))
                out.append(mix(b1, b2, (t - t1) / (t2 - t1)))
            }
        }
        return out
    }
}
