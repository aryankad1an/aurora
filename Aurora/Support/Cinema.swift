import SwiftUI
import UIKit

// MARK: - Cinema
//
// The app's big moments play as short motion graphics rather than as interface:
// the ground washes up over the screen, a figure acts in the middle, a
// serif title rises out of its own baseline, and the whole curtain lifts off the
// top, with film grain boiling over all of it. A queued send and a change from
// writing help use the same curtain, so they read as one film. Smaller AI
// waits use the same grainy ground in place.

/// Where a curtain has got to, handed to its figure so the figure plays in time.
enum CurtainBeat: Int, Comparable {
    /// The ground is washing in.
    case washing
    /// The screen is covered and the figure has the floor.
    case playing
    /// The title is up; the figure is at rest.
    case titled
    /// The curtain is lifting.
    case leaving

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Plays curtains. Each one plays in a window of its own above everything,
/// because what starts it often closes the sheet it was started from: drawn
/// inside the app it would be dragged down with that sheet. A tap lifts it
/// early. Under Reduce Motion it fades in with its figure already at rest,
/// holds, and fades out.
@MainActor
enum Curtain {
    struct Cue {
        var title: String
        var subtitle: String
        /// Read out by VoiceOver as it plays.
        var announcement: String
        /// Where the ground washes in from, in the window's coordinates; nil is
        /// just above the bottom edge, where the buttons that start these sit.
        var origin: CGPoint?
        /// From the screen being covered to the title rising: the figure's act.
        var figureTime = 0.6
        /// How long the finished frame holds before it lifts.
        var hold = 1.25
    }

    private static var window: UIWindow?
    private static var run: Run?

    /// The callbacks of the curtain that's playing, each fired once, so a
    /// curtain cut short by another still finishes what it started.
    private final class Run {
        var covered: (() -> Void)?
        var lifted: (() -> Void)?

        func cover() { covered?(); covered = nil }
        func lift() { cover(); lifted?(); lifted = nil }
    }

    /// Play `cue` with `figure` in the middle. `onCovered` runs once the screen
    /// is hidden (anything changed then changes unseen), `onLifted` once the
    /// curtain has gone.
    static func show<Figure: View>(_ cue: Cue,
                                   onCovered: @escaping () -> Void = {},
                                   onLifted: @escaping () -> Void = {},
                                   @ViewBuilder figure: @escaping (CurtainBeat) -> Figure) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            onCovered()
            onLifted()
            return
        }

        self.run?.lift()
        let run = Run()
        run.covered = onCovered
        run.lifted = onLifted
        self.run = run

        let host = CurtainHost(rootView: AnyView(CurtainStage(
            cue: cue, figure: figure,
            onCovered: { run.cover() },
            onLeave: { restoreStatusBar(run) },
            onFinish: { finish(run) }
        )))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        Self.window = window
        // The clock and battery would sit on the curtain: they step out for it.
        host.hidesStatusBar = true

        UIAccessibility.post(notification: .announcement, argument: cue.announcement)
    }

    private static func restoreStatusBar(_ run: Run) {
        guard run === self.run else { return }
        (window?.rootViewController as? CurtainHost)?.hidesStatusBar = false
    }

    private static func finish(_ run: Run) {
        run.lift()
        // A curtain started meanwhile owns the window now.
        guard run === self.run else { return }
        window?.isHidden = true
        window = nil
        self.run = nil
    }
}

/// Hides the status bar while the curtain is down, from its window above the app's.
private final class CurtainHost: UIHostingController<AnyView> {
    var hidesStatusBar = false {
        didSet {
            UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

private struct CurtainStage<Figure: View>: View {
    let cue: Curtain.Cue
    let figure: (CurtainBeat) -> Figure
    let onCovered: () -> Void
    let onLeave: () -> Void
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The ground has washed over the screen.
    @State private var covered = false
    @State private var beat = CurtainBeat.washing

    private var leaving: Bool { beat == .leaving }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                CinemaGround()
                VStack(spacing: 48) {
                    figure(beat)
                    CinemaCaption(title: cue.title, subtitle: cue.subtitle, isShown: beat >= .titled)
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

    /// The circle the ground washes in through.
    private func wash(_ size: CGSize) -> some View {
        let full = max(size.width, size.height) * 2.4
        let origin = cue.origin ?? CGPoint(x: size.width / 2, y: size.height - 70)
        return Circle()
            .frame(width: covered || reduceMotion ? full : 1, height: covered || reduceMotion ? full : 1)
            .position(origin)
    }

    private func play() async {
        if reduceMotion {
            beat = .titled
            withAnimation(.easeOut(duration: 0.25)) { covered = true }
            await sleep(0.25)
            onCovered()
            await sleep(cue.hold + 1)
            await leave()
            return
        }
        Haptics.lift(0.5)
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.55)) { covered = true }
        await sleep(0.32)
        guard !leaving else { return }
        beat = .playing
        await sleep(0.23)
        onCovered()
        await sleep(max(cue.figureTime - 0.23, 0))
        guard !leaving else { return }
        withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.55)) { beat = .titled }
        await sleep(cue.hold)
        await leave()
    }

    private func leave() async {
        guard !leaving else { return }
        onLeave()
        withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .timingCurve(0.7, 0, 0.84, 0, duration: 0.5)) {
            beat = .leaving
        }
        await sleep(reduceMotion ? 0.3 : 0.5)
        onFinish()
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Pieces

/// The curtain's ground: the paper, lit from above the middle by the accent,
/// under boiling grain. Also the ground for an AI wait in place.
struct CinemaGround: View {
    /// How strongly the accent lights it.
    var glow = 0.30

    var body: some View {
        ZStack {
            Color.paper
            RadialGradient(colors: [Color.clay.opacity(glow), .clear],
                           center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 420)
            FilmGrain()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A serif title that rises out of its own baseline, as titles do in motion
/// graphics, with a line under it that fades up behind.
struct CinemaCaption: View {
    let title: String
    var subtitle: String?
    let isShown: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .offset(y: isShown ? 0 : 56)
                .clipped()
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                    .opacity(isShown ? 1 : 0)
                    .offset(y: isShown ? 0 : 10)
            }
        }
    }
}

/// Rings spreading out behind a curtain's figure as the ground comes in.
struct CinemaRings: View {
    let isOut: Bool

    var body: some View {
        ForEach(0..<3, id: \.self) { ring in
            Circle()
                .stroke(Color.ink.opacity(0.07 - Double(ring) * 0.018), lineWidth: 1)
                .frame(width: 230 + CGFloat(ring) * 120, height: 230 + CGFloat(ring) * 120)
                .scaleEffect(isOut ? 1 : 0.55)
                .animation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 1.1).delay(Double(ring) * 0.08),
                           value: isOut)
        }
    }
}

extension View {
    /// A flat card with a hard offset shadow, like a print: the look of every
    /// figure on a curtain.
    func printed(cornerRadius: CGFloat, fill: Color) -> some View {
        let card = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    card.fill(.black.opacity(0.42)).offset(x: 7, y: 9)
                    card.fill(fill)
                }
            }
            .overlay { card.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
    }
}

// MARK: - Grain

/// Film grain. A tile of random specks, shifted to a new place twelve times a
/// second so it boils like grain on film; still when `boils` is off (the
/// ground under every screen) and under Reduce Motion.
struct FilmGrain: View {
    var boils = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || !boils {
                grain(frame: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
                    grain(frame: Int(context.date.timeIntervalSinceReferenceDate * 12))
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func grain(frame: Int) -> some View {
        let side = max(Self.tile.size.width, 1)
        let x = CGFloat((frame &* 73) % Int(side))
        let y = CGFloat((frame &* 151) % Int(side))
        return Rectangle()
            .fill(ImagePaint(image: Image(uiImage: Self.tile)))
            .padding(-side)
            .offset(x: -x, y: -y)
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
