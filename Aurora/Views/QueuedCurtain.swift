import SwiftUI
import UIKit

/// The moment a batch is handed to the queue, as a short full-screen motion
/// graphic: the theme's ground washes up over the screen from where Send sits,
/// envelopes drop one by one onto a stack while its count ticks up, "Queued"
/// rises in under it, and the whole curtain lifts off the top. Film grain boils
/// over all of it, so it reads as animation rather than as interface.
///
/// It plays in a window of its own above everything, because the send closes
/// the sheet it was started from: drawn inside the app it would be dragged
/// down with that sheet. A tap lifts it early. Under Reduce Motion it fades in
/// with the stack already at rest, holds, and fades out.
@MainActor
enum QueuedCurtain {
    private static var window: UIWindow?
    private static var generation = 0

    /// Announce `count` mails queued. With `scheduledFor`, it names the time
    /// they'll go instead.
    static func show(count: Int, scheduledFor: Date? = nil) {
        guard count > 0,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }

        generation += 1
        let run = generation
        let host = CurtainHost(rootView: QueuedCurtainView(
            count: count, scheduledFor: scheduledFor,
            onLeave: { restoreStatusBar(run) },
            onFinish: { finish(run) }
        ))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        Self.window = window
        // The clock and battery would sit on the curtain: they step out for it.
        host.hidesStatusBar = true

        let what = count == 1 ? "1 mail" : "\(count) mails"
        UIAccessibility.post(notification: .announcement,
                             argument: scheduledFor == nil ? "Queued \(what)" : "Scheduled \(what)")
    }

    private static func restoreStatusBar(_ run: Int) {
        guard run == generation else { return }
        (window?.rootViewController as? CurtainHost)?.hidesStatusBar = false
    }

    private static func finish(_ run: Int) {
        // A second send started meanwhile owns the window now.
        guard run == generation else { return }
        window?.isHidden = true
        window = nil
    }
}

/// Hides the status bar while the curtain is down, from its window above the app's.
private final class CurtainHost: UIHostingController<QueuedCurtainView> {
    var hidesStatusBar = false {
        didSet {
            UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

private struct QueuedCurtainView: View {
    let count: Int
    let scheduledFor: Date?
    let onLeave: () -> Void
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The ground has washed over the screen.
    @State private var covered = false
    /// Envelopes on the stack so far.
    @State private var landed = 0
    /// The count on the stack's badge.
    @State private var shown = 0
    @State private var titled = false
    /// The curtain is going, or gone.
    @State private var leaving = false

    /// At most three envelopes drop; the badge carries the rest.
    private var drops: Int { min(count, 3) }

    /// Each envelope's tilt as it falls, and once it's on the stack.
    private static let fallTilt: [Double] = [-24, 19, -11]
    private static let restTilt: [Double] = [-5, 4, -1.5]
    /// How far each envelope sits above the one under it.
    private static let step: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ground
                VStack(spacing: 48) {
                    stack(fallFrom: size.height)
                    caption
                }
                .padding(.horizontal, 32)
                // The content goes off the top a little ahead of the ground.
                .offset(y: leaving && !reduceMotion ? -90 : 0)
            }
            .mask { wash(size) }
            .offset(y: leaving && !reduceMotion ? -size.height : 0)
            .opacity(reduceMotion ? (covered && !leaving ? 1 : 0) : 1)
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { Task { await leave() } }
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task { await play() }
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    private var ground: some View {
        ZStack {
            Color.paper
            RadialGradient(colors: [Color.clay.opacity(0.30), .clear],
                           center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 420)
            FilmGrain(boils: !reduceMotion)
        }
    }

    /// The circle the ground washes in through, from where Send sits.
    private func wash(_ size: CGSize) -> some View {
        let full = max(size.width, size.height) * 2.4
        return Circle()
            .frame(width: covered || reduceMotion ? full : 1, height: covered || reduceMotion ? full : 1)
            .position(x: size.width / 2, y: size.height - 70)
    }

    private func stack(fallFrom height: CGFloat) -> some View {
        ZStack {
            // Rings spreading out behind the stack as the ground comes in.
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(Color.ink.opacity(0.07 - Double(ring) * 0.018), lineWidth: 1)
                    .frame(width: 230 + CGFloat(ring) * 120, height: 230 + CGFloat(ring) * 120)
                    .scaleEffect(covered ? 1 : 0.55)
                    .animation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 1.1).delay(Double(ring) * 0.08),
                               value: covered)
            }

            ZStack {
                ForEach(0..<drops, id: \.self) { index in
                    let down = landed > index
                    EnvelopeMark(depth: Double(drops - 1 - index) * 0.18)
                        .rotationEffect(.degrees(down ? Self.restTilt[index] : Self.fallTilt[index]))
                        .offset(y: down ? -CGFloat(index) * Self.step : -height)
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

    private var caption: some View {
        VStack(spacing: 10) {
            Text(scheduledFor == nil ? "Queued" : "Scheduled")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(Color.ink)
                // Rises out of its own baseline, as titles do in motion graphics.
                .offset(y: titled ? 0 : 56)
                .clipped()
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .opacity(titled ? 1 : 0)
                .offset(y: titled ? 0 : 10)
        }
    }

    private var subtitle: String {
        if let scheduledFor {
            let when = scheduledFor.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "\(count == 1 ? "1 mail goes" : "\(count) mails go") out \(when)"
        }
        return count == 1 ? "Going out from your Gmail now" : "\(count) mails, going out one after another"
    }

    // MARK: - Playing

    private func play() async {
        if reduceMotion {
            landed = drops
            shown = count
            titled = true
            withAnimation(.easeOut(duration: 0.25)) { covered = true }
            await sleep(2.2)
            await leave()
            return
        }
        Haptics.lift(0.5)
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.55)) { covered = true }
        await sleep(0.32)
        for index in 0..<drops {
            guard !leaving else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.36)) { landed = index + 1 }
            await sleep(0.15)
            Haptics.tap(0.45 + CGFloat(index) * 0.15)
            withAnimation(.snappy(duration: 0.3)) { shown = index == drops - 1 ? count : index + 1 }
            await sleep(0.1)
        }
        guard !leaving else { return }
        withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.55)) { titled = true }
        await sleep(1.25)
        await leave()
    }

    private func leave() async {
        guard !leaving else { return }
        onLeave()
        withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .timingCurve(0.7, 0, 0.84, 0, duration: 0.5)) {
            leaving = true
        }
        await sleep(reduceMotion ? 0.3 : 0.5)
        onFinish()
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// A flat envelope in the theme's accent, with a hard offset shadow like a
/// print: `depth` darkens the ones further down the stack.
private struct EnvelopeMark: View {
    let depth: Double

    var body: some View {
        let card = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            card.fill(.black.opacity(0.42)).offset(x: 7, y: 9)
            card.fill(Color.clay.mix(with: .black, by: depth))
            Flap()
                .stroke(Color.paper.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .padding(16)
            card.strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .frame(width: 150, height: 104)
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

/// Film grain over the whole curtain. A tile of random specks, shifted to a new
/// place twelve times a second so it boils like grain on film; still when
/// `boils` is off.
private struct FilmGrain: View {
    let boils: Bool

    var body: some View {
        if boils {
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
                grain(frame: Int(context.date.timeIntervalSinceReferenceDate * 12))
            }
        } else {
            grain(frame: 0)
        }
    }

    private func grain(frame: Int) -> some View {
        let side = max(Self.tile.size.width, 1)
        let x = CGFloat((frame &* 73) % Int(side))
        let y = CGFloat((frame &* 151) % Int(side))
        return Rectangle()
            .fill(ImagePaint(image: Image(uiImage: Self.tile)))
            .padding(-side)
            .offset(x: -x, y: -y)
            .allowsHitTesting(false)
    }

    /// 256 pixels square at twice the point size, so each speck is about a
    /// pixel and a half on screen: light and dark specks, each faint.
    private static let tile: UIImage = {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var random = SystemRandomNumberGenerator()
        for index in 0..<(side * side) {
            let alpha = UInt8.random(in: 0...56, using: &random)
            // Premultiplied: a light speck's colour is its alpha, a dark one's is 0.
            let value = Bool.random(using: &random) ? alpha : 0
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = alpha
        }
        let image = pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return UIImage() }
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}
