import SwiftUI

/// The app's root: a bottom tab bar (Home, Companies, Activity, Templates,
/// Settings). Owns the shared stores and injects them into the environment.
struct RootView: View {
    /// Applied once, before the first bar is drawn. The Taptic Engine is primed
    /// at the same time so the first knock of a session isn't the late one.
    init() {
        AppAppearance.apply()
        Haptics.prepare()
    }

    @State private var jobStore = JobStore()
    @State private var profileStore = ProfileStore()
    @State private var templateStore = TemplateStore()
    @State private var gmailAuth = GmailAuthStore()
    @State private var mailQueue = MailQueue()
    @State private var replySync = ReplySync()
    @State private var selectionChrome = SelectionChrome()
    @State private var selectedTab: Tab = .home
    /// Taps on scheduled-mail notifications, which can arrive before the app
    /// has finished opening.
    private let notifications = NotificationRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    /// How many of the launch loads have finished, out of `bootUnits`. Drives the
    /// splash's rule and the rising ticks that go with it.
    @State private var bootDone = 0
    /// False until every store this app opens with has answered. One flag for all
    /// of them, because the alternative is what this replaced: the profile gating
    /// a splash, then each tab arriving on screen empty and filling itself in.
    @State private var isBooted = false

    /// Profile, templates, companies. Named as a constant because the splash's
    /// progress is a real fraction of these, not a timer dressed up as one.
    private static let bootUnits = 3

    /// The floor on how long the splash stays up. A warm launch can finish all
    /// three loads in a couple of hundred milliseconds, and a launch screen that
    /// appears and vanishes inside one is a flicker, not a screen.
    private static let minimumSplash: Duration = .milliseconds(1_150)
    /// A beat after the last load, for the splash's final droplet to land.
    private static let settleBeat: Duration = .milliseconds(380)

    /// How stale a check has to be before returning to the app runs another.
    /// Without a floor, every glance at the home screen and back would spend a
    /// request per outstanding thread.
    private static let resyncAfter: TimeInterval = 15 * 60

    private enum Tab: Hashable { case home, companies, activity, templates, settings }

    var body: some View {
        Group {
            if let email = gmailAuth.connectedEmail {
                signedInContent
                    // One launch, for the whole app. Re-runs if the connected
                    // account changes, which is a new launch as far as the data
                    // is concerned.
                    .task(id: email) { await boot(email: email) }
            } else {
                LoginView()
            }
        }
        // The window's own background is black; paper behind everything means no
        // transition, scale or blur anywhere can ever reveal it.
        .background(Color.paper.ignoresSafeArea())
        // One appearance: every theme's palette is dark, so every piece of
        // system chrome (sheets, alerts, keyboards, glass) is told to match it.
        .preferredColorScheme(.dark)
        // System controls take the theme's accent, and change with it.
        .tint(Color.clay)
        .environment(jobStore)
        .environment(profileStore)
        .environment(templateStore)
        .environment(gmailAuth)
        .environment(mailQueue)
        .environment(replySync)
        .environment(selectionChrome)
        // Block interaction and show a loading state while a change is being
        // written to the database and reloaded, so the two never drift.
        .overlay {
            if jobStore.isSaving || templateStore.isSaving {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .transition(.opacity)
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Saving…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.ink)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.glassPop)
                }
            }
        }
        // A theme change spreads across the screen from the tapped card.
        .overlay { ThemeWashOverlay() }
        .animation(Theme.Motion.liquid, value: jobStore.isSaving)
        .animation(Theme.Motion.liquid, value: templateStore.isSaving)
        // A failed write is the one thing on this screen the user has to act on,
        // so it announces itself before the alert has finished animating in.
        .sensoryFeedback(trigger: activeError != nil) { _, hasError in
            hasError ? .error : nil
        }
        // Surface any write/load failure from any tab. All three stores report
        // here: template and profile failures used to set an `errorMessage` that
        // no view was bound to, so a save that never reached the database looked
        // exactly like one that did.
        .messageAlert("Something went wrong", message: activeError) { clearErrors() }
    }

    private var activeError: String? {
        jobStore.errorMessage ?? templateStore.errorMessage ?? profileStore.errorMessage
    }

    private func clearErrors() {
        jobStore.clearError()
        templateStore.clearError()
        profileStore.clearError()
    }

    /// Signed-in flow: hold the splash until everything has loaded, onboard
    /// first-time users, then show the tabs — already populated.
    @ViewBuilder
    private var signedInContent: some View {
        // The splash sits *over* the app rather than swapping with it. Swapping
        // meant the arriving screen was scaled and blurred on its own, which
        // pulled its edges in and showed the black window behind them as bars
        // above and below. Layered, the app is already full-size underneath and
        // the splash dissolves off the top of it.
        ZStack {
            if isBooted {
                signedInApp
                    .transition(.opacity)
            }
            if !isBooted {
                SplashView(progress: Double(bootDone) / Double(Self.bootUnits))
                    .transition(LiquidDissolve())
                    .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private var signedInApp: some View {
        if !profileStore.hasProfile {
            OnboardingView()
                .transition(LiquidMaterialize(scale: 1))
        } else {
            tabs
                .transition(.opacity)
                // Replies arrive while the app is closed, so coming back is
                // exactly when the answer on screen is most likely to be stale.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Back in the app: a scheduled batch may have come due.
                    mailQueue.tick()
                    guard !replySync.isSyncing else { return }
                    let last = replySync.lastSyncedAt ?? .distantPast
                    guard Date().timeIntervalSince(last) > Self.resyncAfter else { return }
                    Task { await jobStore.syncReplies(using: replySync) }
                }
        }
    }

    // MARK: - Launch

    /// Load everything this account opens with, at once, behind the splash.
    ///
    /// The three loads are independent requests to two different services, so
    /// they run concurrently: launch costs the slowest of them rather than their
    /// sum. They used to run one after another *and* in two places — profile and
    /// templates here, companies in the tabs' own task — which is why the app used
    /// to appear before it had anything to show.
    ///
    /// Reply syncing is deliberately left out. It is a Gmail request per
    /// outstanding thread, so it can run for seconds on a busy account; it starts
    /// once the app is on screen and reports itself on Activity.
    private func boot(email: String) async {
        isBooted = false
        bootDone = 0
        jobStore.userEmail = email
        connectMailQueue()
        mailQueue.load(account: email)
        replySync.loadBounces(account: email)

        let started = ContinuousClock.now
        async let profile: Void = load { await profileStore.load(email: email) }
        async let templates: Void = load { await templateStore.load(email: email) }
        async let companies: Void = load { await jobStore.load() }
        _ = await (profile, templates, companies)

        // Hold the floor from the moment the launch began, so a slow load spends
        // none of it and a fast one still gets a whole screen rather than a blink.
        let elapsed = ContinuousClock.now - started
        if elapsed < Self.minimumSplash {
            try? await Task.sleep(for: Self.minimumSplash - elapsed)
        }
        // Let the last droplet finish fusing before the splash dissolves; cutting
        // it off mid-glide is the one jolt left in an otherwise continuous launch.
        try? await Task.sleep(for: Self.settleBeat)

        Haptics.success()
        withAnimation(.smooth(duration: 0.75)) { isBooted = true }

        // A notification tapped to open the app: its batch is asked about now.
        openTappedBatch()
        // Settle anything the last session left mid-send: whether each mail cut
        // off went out, and any send not yet in the history. Not awaited — a
        // mail cut off moments ago is given a few seconds to show up in Sent.
        Task { await mailQueue.reconcile() }

        // Full, not delta: the sync state may be left over from another account,
        // and a delta against its timestamp would skip this account's threads.
        await jobStore.syncReplies(using: replySync, forceFullCheck: true)
    }

    /// Run one launch load and mark it done: the rule advances a third, and the
    /// phone ticks a little harder than it did for the one before. Three rising
    /// taps and the success note at the end — the same shape as `Haptics.cascade`,
    /// paced by the network instead of by a timer, so the launch is something you
    /// can feel finishing without looking.
    private func load(_ work: () async -> Void) async {
        await work()
        bootDone += 1
        Haptics.tap(0.45 + 0.15 * CGFloat(bootDone))
    }

    /// Hand the queue the two things it deliberately doesn't own: how to deliver a
    /// mail, and what to do with the sends once a run finishes.
    private func connectMailQueue() {
        mailQueue.sender = { recipient, subject, body, fromName in
            do {
                let message = try await gmailAuth.send(to: recipient, subject: subject,
                                                       body: body, fromName: fromName)
                return message.map { MailQueue.Delivery(messageID: $0.id, threadID: $0.threadID) }
            } catch let error as GmailAuthError where error.needsReconnect {
                // The shelf says "Reconnect Gmail in Settings"; make sure
                // Settings is offering it.
                replySync.noteReconnectNeeded()
                throw error
            }
        }
        mailQueue.verifier = { recipient, since in
            try await gmailAuth.findSent(to: recipient, since: since)
                .map { MailQueue.Delivery(messageID: $0.id, threadID: $0.threadID) }
        }
        mailQueue.onRecord = { records in
            await jobStore.markContactsSent(records)
        }
        replySync.reader = { path, query in
            try await gmailAuth.gmailGET(path: path, query: query)
        }
    }

    /// Ask about the batch whose notification was tapped.
    private func openTappedBatch() {
        guard let id = notifications.openedBatchID else { return }
        notifications.openedBatchID = nil
        mailQueue.unsnooze(id)
    }

    /// The send queue's shelf above the tab bar, shown only while the queue has
    /// something to say. It steps aside while a list is selecting: the tab bar
    /// leaves then, and the shelf would drop into its place on top of the
    /// selection toolbar's Send and Delete.
    private var tabs: some View {
        tabStack
            .tabViewBottomAccessory(isEnabled: mailQueue.isActive && !selectionChrome.isSelecting) {
                // The shelf only ever opens the queue; a result it was showing
                // has been seen once the queue is open.
                SendQueueBar {
                    mailQueue.acknowledge()
                    mailQueue.openRequest = .inProgress
                }
            }
            .dueBatchSummary()
            // The queue lives in Activity: the shelf, the Live Activity and a
            // notification all open it there.
            .onChange(of: mailQueue.openRequest) { _, request in
                if request != nil { selectedTab = .activity }
            }
            .onOpenURL { url in
                guard url.scheme == "aurora", url.host() == "activity" else { return }
                mailQueue.openRequest = url.lastPathComponent == "queued" ? .queued : .inProgress
            }
            .onChange(of: notifications.openedBatchID) { openTappedBatch() }
            // The shelf appearing pushes the tab bar up — a real object arriving on
            // screen, and the one event here the user didn't just tap for.
            .sensoryFeedback(trigger: mailQueue.isActive) { _, active in
                active ? .impact(weight: .medium, intensity: 0.6) : nil
            }
    }

    private var tabStack: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            CompaniesView()
                .tabItem { Label("Companies", systemImage: "building.2") }
                .tag(Tab.companies)

            ActivityView()
                .tabItem { Label("Activity", systemImage: "tray.full") }
                // Bounces are the one thing in Activity waiting on the user.
                .badge(jobStore.bouncedContacts(from: replySync).count)
                .tag(Tab.activity)

            TemplatesView()
                .tabItem { Label("Templates", systemImage: "doc.plaintext") }
                .tag(Tab.templates)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
    }
}

#Preview {
    RootView()
}
