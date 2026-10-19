import SwiftUI
import UIKit

/// The moment a batch leaves, said the way the system says things: the Dynamic
/// Island opens out into "Sending mails", holds for a beat, and tucks back up.
/// iOS keeps an app's own Live Activity out of the island while the app is on
/// screen, so the app draws this one itself, over the island's own shape; once
/// the app is left, the Live Activity carries on from it.
///
/// It plays in a window of its own above everything, with touches passing
/// straight through, because the send closes the sheet it was started from:
/// drawn inside the app it would be dragged down with that sheet.
///
/// On a phone without an island it drops from the top edge instead, and under
/// Reduce Motion it fades in and out in place.
@MainActor
enum SendIsland {
    private static var window: UIWindow?
    private static var generation = 0

    /// Announce `count` mails going. With `scheduledFor`, it names the time
    /// they'll go instead.
    static func show(count: Int, scheduledFor: Date? = nil) {
        guard count > 0,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }

        generation += 1
        let run = generation
        // Phones with an island inset their top safe area past 50 points.
        let hasIsland = (scene.keyWindow?.safeAreaInsets.top ?? 0) > 50
        let host = IslandHost(rootView: SendIslandView(count: count, scheduledFor: scheduledFor,
                                                       hasIsland: hasIsland))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.rootViewController = host
        window.isHidden = false
        Self.window = window
        // The clock and battery would sit on top of the opened island: they
        // step out for it, as they do for the system's.
        host.hidesStatusBar = true

        Task {
            try? await Task.sleep(for: SendIslandView.duration - .milliseconds(450))
            guard run == generation else { return }
            host.hidesStatusBar = false
            try? await Task.sleep(for: .milliseconds(450))
            // A second send started meanwhile owns the window now.
            guard run == generation else { return }
            Self.window?.isHidden = true
            Self.window = nil
        }
    }
}

/// Hides the status bar while the island is open, from its window above the app's.
private final class IslandHost: UIHostingController<SendIslandView> {
    var hidesStatusBar = false {
        didSet {
            UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

private struct SendIslandView: View {
    let count: Int
    let scheduledFor: Date?
    let hasIsland: Bool

    /// How long the window stays up: opened, held, and closed again.
    static let duration: Duration = .milliseconds(3_200)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    @State private var showsContent = false
    @State private var lifted = 0

    var body: some View {
        GeometryReader { proxy in
            let closed = closedRect(width: proxy.size.width)
            let opened = openRect(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                IslandShape(from: closed, to: opened, progress: open ? 1 : 0)
                    .fill(Color.black)
                    .opacity(hasIsland || open ? 1 : 0)
                content
                    .frame(width: opened.width, height: opened.height)
                    .offset(x: opened.minX, y: opened.minY)
                    .opacity(showsContent ? 1 : 0)
                    .blur(radius: showsContent || reduceMotion ? 0 : 6)
                    .scaleEffect(showsContent || reduceMotion ? 1 : 0.92, anchor: .top)
            }
            .opacity(reduceMotion ? (open ? 1 : 0) : 1)
        }
        .ignoresSafeArea()
        // The island has a fixed height, so its text stops growing as the system's does.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .environment(\.colorScheme, .dark)
        .task { await play() }
        .accessibilityHidden(true)
    }

    private var title: String {
        if scheduledFor != nil { return "Scheduled" }
        return count == 1 ? "Sending mail" : "Sending mails"
    }

    private var subtitle: String {
        if let scheduledFor {
            return "\(count) \(count == 1 ? "mail goes" : "mails go") \(scheduledFor.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return count == 1 ? "On its way from your Gmail" : "\(count) mails, one after another"
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: scheduledFor == nil ? "paperplane.fill" : "clock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: lifted)
                .frame(width: 40, height: 40)
                .background(Color.clay, in: .rect(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
    }

    /// Where the hardware island sits, or a speck at the top edge without one.
    private func closedRect(width: CGFloat) -> CGRect {
        hasIsland ? CGRect(x: (width - 126) / 2, y: 11, width: 126, height: 37)
                  : CGRect(x: (width - 40) / 2, y: -30, width: 40, height: 30)
    }

    /// The island opened out, as the system opens it for a Live Activity.
    private func openRect(width: CGFloat) -> CGRect {
        CGRect(x: 11, y: hasIsland ? 11 : 8, width: width - 22, height: 76)
    }

    private func play() async {
        if reduceMotion {
            open = true
            showsContent = true
            await sleep(2.6)
            withAnimation(.easeIn(duration: 0.3)) { open = false }
            return
        }
        await sleep(0.05)
        Haptics.lift(0.5)
        withAnimation(.spring(duration: 0.5, bounce: 0.28)) { open = true }
        await sleep(0.18)
        withAnimation(.easeOut(duration: 0.3)) { showsContent = true }
        await sleep(0.25)
        lifted += 1
        await sleep(1.9)
        withAnimation(.easeIn(duration: 0.16)) { showsContent = false }
        await sleep(0.1)
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { open = false }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// A capsule-cornered rectangle moving from one rect to another as `progress`
/// goes 0 to 1. Drawn from the interpolated rect, so every frame of the spring
/// stays centred where an animated frame and offset drift apart.
private nonisolated struct IslandShape: Shape {
    let from: CGRect
    let to: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        let box = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                         width: mix(from.width, to.width), height: mix(from.height, to.height))
        // Fully round while closed, easing to the open island's softer corners.
        let radius = min(box.height / 2, mix(from.height / 2, 38))
        return Path(roundedRect: box, cornerRadius: radius, style: .continuous)
    }
}
