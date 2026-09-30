import SwiftUI

/// Quick Actions: the three moves you can make on your outreach, each with the
/// send that follows it one tap away.
///
/// It replaces the old Insights screen. That one scored the campaign — a ring, a
/// median, a hero panel — and then left you to go and act on it somewhere else.
/// The scoring is now one strip across the top, and everything under it is a
/// list you can tick and send:
///
/// - **Waiting** — every unanswered mail, one row per person, filtered by how
///   long the silence has run. Pick "7d+" and you are looking at exactly the
///   follow-ups that are due.
/// - **Replied** — who wrote back and what they said.
/// - **New** — people who can still be mailed and haven't been in the last month.
///
/// Both sendable lanes carry the same bar: tick the rows you want, or send the
/// whole lane. Nothing leaves from here directly — the batch opens the same
/// compose-and-review sheet a per-company send does.
struct QuickActionsView: View {
    @Environment(JobStore.self) private var jobStore
    @Environment(ReplySync.self) private var replySync
    @Environment(\.dismiss) private var dismiss

    enum Lane: Int, Hashable, CaseIterable { case waiting, replied, reachOut }

    @State private var lane: Lane = .waiting
    /// Which way the next lane swap travels: +1 when the incoming lane sits to
    /// the right of the outgoing one, -1 when it sits to the left. Set by the
    /// selector's binding *before* the lane changes, so the transition is already
    /// pointing the right way when the new lane is inserted.
    @State private var direction: Double = 1
    /// Show only mails quiet for at least this many days; 0 shows every one.
    /// Remembered across launches — the threshold you work at is a habit, not a
    /// per-visit decision.
    @AppStorage("quickActions.waitingDays") private var waitingDays = 0
    /// The rows ticked for the next batch. Cleared whenever the set under it
    /// changes, so a tick can never survive into a list that no longer shows it.
    @State private var selection: Set<Contact.ID> = []
    @State private var summaryItem: ActivityEntry?
    @State private var sendBatch: SendBatch?
    /// The bounce banner's Mark, held until it's confirmed.
    @State private var pendingValidity: ValidityChange?
    @State private var path = NavigationPath()
    @Namespace private var zoom

    /// The silences worth cutting at. Coarse on purpose: a day-by-day slider
    /// would invite fiddling with a number that only ever means "a few days", "a
    /// week", "a fortnight", "a month".
    private static let dayOptions = [0, 3, 7, 14, 30]

    private var insights: Insights { jobStore.insights }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    StatusStrip(insights: insights, sync: replySync) {
                        Task { await sync() }
                    }

                    if !bouncedContacts.isEmpty { bounceBanner }

                    SegmentedSelector(segments: [
                        (.waiting, "Waiting"),
                        (.replied, "Replied"),
                        (.reachOut, "New")
                    ], selection: laneBinding)

                    laneContent
                        .transition(.glassSwap(direction: direction))
                }
                .animation(Theme.Motion.bouncy, value: lane)
                .animation(Theme.Motion.bouncy, value: waitingDays)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { companyID in
                // The card the user tapped grows into the company screen, and
                // shrinks back into its place on the way out.
                JobDetailView(jobID: companyID)
                    .navigationTransition(.zoom(sourceID: companyID, in: zoom))
            }
            .toolbar {
                // Trailing, like every other sheet here that's only read and
                // closed: leading is where Cancel goes when there's work to lose.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbar { sendToolbar }
            .refreshable { await sync() }
            .validityAlert($pendingValidity) { change in
                Task { await jobStore.markBouncedInvalid(change.ids, sync: replySync) }
            }
            // A check that actually found something is the one moment this screen
            // changes on its own, so it gets the double-tap "arrived" knock. A
            // check that found nothing stays silent rather than claiming news —
            // this fires on the sync finishing, not on the count being non-zero,
            // so it can't re-announce the same replies on every refresh.
            .onChange(of: replySync.lastSyncedAt) { _, _ in
                if (replySync.lastOutcome?.replies ?? 0) > 0 { Haptics.arrival() }
            }
            // A tick only means anything against the list it was made in.
            .onChange(of: lane) { selection.removeAll() }
            .onChange(of: waitingDays) { selection.removeAll() }
            .animation(Theme.Motion.bouncy, value: bouncedContacts.count)
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
            .sheet(item: $sendBatch) { batch in
                SendMailView(title: batch.title, recipients: batch.recipients) {
                    sendBatch = nil
                    selection.removeAll()
                }
            }
        }
    }

    /// The selector writes through here rather than to `lane` directly, so the
    /// travel direction is decided before the swap animates.
    private var laneBinding: Binding<Lane> {
        Binding {
            lane
        } set: { next in
            direction = next.rawValue >= lane.rawValue ? 1 : -1
            lane = next
        }
    }

    // MARK: - Lanes

    @ViewBuilder
    private var laneContent: some View {
        switch lane {
        case .waiting: waitingLane
        case .replied: repliedLane
        case .reachOut: reachOutLane
        }
    }

    /// Unanswered mails older than the chosen threshold, longest silence first.
    /// The order is the whole point: the top of this list is the follow-up you
    /// should write today.
    @ViewBuilder
    private var waitingLane: some View {
        let mails = waitingMails
        VStack(spacing: 12) {
            SegmentedSelector(segments: Self.dayOptions.map {
                (value: $0, title: $0 == 0 ? "Any" : "\($0)d+")
            }, selection: $waitingDays)

            if mails.isEmpty {
                InlineEmptyState(
                    title: emptyWaitingTitle,
                    systemImage: insights.totalSent == 0 ? "paperplane" : "checkmark.seal.fill",
                    message: emptyWaitingMessage,
                    tint: insights.totalSent == 0 ? .inkMuted : .statusDone
                )
            } else {
                laneCaption("\(mails.count) unanswered"
                            + (waitingDays == 0 ? "" : " · quiet \(waitingDays)+ days"))
                ForEach(mails) { mail in
                    Button { toggle(mail.contact.id, enabled: mail.isMailable) } label: {
                        WaitingRow(mail: mail, isSelected: selection.contains(mail.contact.id))
                    }
                    .cardButtonStyle()
                    // The company screen is one hold away rather than one tap:
                    // on a screen built for picking recipients, a tap has to mean
                    // "pick this one".
                    .contextMenu {
                        if let id = mail.companyID {
                            Button("Open \(mail.company)", systemImage: "building.2") {
                                path.append(id)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Who wrote back, most recent first, each with the first line of what they
    /// actually said — a reply you can't read is just a badge.
    @ViewBuilder
    private var repliedLane: some View {
        if insights.replies.isEmpty {
            InlineEmptyState(
                title: "No replies yet",
                systemImage: "tray",
                message: "Answers show up here as soon as they land in Gmail.",
                tint: .statusDone
            )
        } else {
            LazyVStack(spacing: 12) {
                laneCaption("\(insights.repliedPeople) "
                            + (insights.repliedPeople == 1 ? "person answered" : "people answered"))
                ForEach(insights.replies) { entry in
                    Button { summaryItem = entry } label: {
                        ReplyCard(entry: entry)
                    }
                    .cardButtonStyle()
                }
            }
        }
    }

    /// People who can still be mailed and haven't been in the last month,
    /// gathered under the company they work at.
    ///
    /// Grouped rather than flat because a mail is a decision about a
    /// *company* first — you go after Stripe, and then decide whether that means
    /// one contact or all three. The card header ticks the whole company; the
    /// rows inside tick one person each, so the two ways of thinking about it
    /// cost the same single tap.
    ///
    /// Companies keep the flat list's urgency order: each appears at the
    /// position of its most-overdue person.
    @ViewBuilder
    private var reachOutLane: some View {
        let groups = jobStore.suggestedGroups
        if groups.isEmpty {
            InlineEmptyState(
                title: "All caught up",
                systemImage: "checkmark.circle",
                message: "Everyone reachable has been mailed in the last month.",
                tint: .clay
            )
        } else {
            let people = groups.reduce(0) { $0 + $1.contacts.count }
            LazyVStack(spacing: 12) {
                laneCaption("\(people) ready to reach out · "
                            + "\(groups.count) compan\(groups.count == 1 ? "y" : "ies")")
                ForEach(groups, id: \.company.id) { group in
                    CompanyGroupCard(
                        company: group.company.company,
                        isTracked: jobStore.isTracked(group.company.id),
                        contacts: group.contacts,
                        selection: selection,
                        onToggleCompany: { toggleAll(in: group.contacts) },
                        onToggleContact: { toggle($0, enabled: true) }
                    )
                    .matchedTransitionSource(id: group.company.id, in: zoom)
                    .contextMenu {
                        Button("Open \(group.company.company)", systemImage: "building.2") {
                            path.append(group.company.id)
                        }
                    }
                    .onAppear {
                        if group.company.id == groups.last?.company.id {
                            Task { await jobStore.loadMoreCompanies() }
                        }
                    }
                }

                if jobStore.isLoadingMoreCompanies { LoadingRow() }
            }
        }
    }

    /// One line under the selector saying what the lane is currently showing.
    /// It replaces the section headers each lane used to carry: with the selector
    /// directly above naming the lane, a header restating it was furniture.
    private func laneCaption(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.caption)
                .foregroundStyle(.inkMuted)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var emptyWaitingTitle: String {
        if insights.totalSent == 0 { return "Nothing sent yet" }
        if waitingDays > 0 && !insights.waitingMails.isEmpty { return "Nothing quiet that long" }
        return "Everyone has answered"
    }

    private var emptyWaitingMessage: String {
        if insights.totalSent == 0 { return "Send your first mail and this fills in." }
        if waitingDays > 0 && !insights.waitingMails.isEmpty {
            return "\(insights.waitingMails.count) still unanswered, all newer than \(waitingDays) days."
        }
        return "Every mail you've sent has been replied to."
    }

    // MARK: - Selection + sending

    /// The waiting list cut to the chosen age.
    private var waitingMails: [Insights.WaitingMail] {
        insights.waitingMails.filter { $0.days >= waitingDays }
    }

    /// Everyone the current lane could mail, in the order they're listed. Empty
    /// for Replied, which is a reading lane — there is nothing to send there.
    private var targets: [(contact: Contact, company: String)] {
        switch lane {
        case .waiting:
            return waitingMails.filter(\.isMailable).map { (contact: $0.contact, company: $0.company) }
        case .reachOut:
            return jobStore.suggestedContacts.map { (contact: $0.contact, company: $0.company.company) }
        case .replied:
            return []
        }
    }

    private var picked: [(contact: Contact, company: String)] {
        targets.filter { selection.contains($0.contact.id) }
    }

    private func toggle(_ id: Contact.ID, enabled: Bool) {
        guard enabled else { Haptics.warning(); return }
        Haptics.select()
        withAnimation(Theme.Motion.pop) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

    /// Tick a whole company, or clear it if it's already fully ticked. Partly
    /// ticked counts as "not yet", so the header always completes the set the
    /// first time it's tapped rather than undoing the rows you just picked.
    private func toggleAll(in contacts: [Contact]) {
        let ids = contacts.map(\.id)
        guard !ids.isEmpty else { return }
        Haptics.press()
        withAnimation(Theme.Motion.pop) {
            if ids.allSatisfy(selection.contains) {
                selection.subtract(ids)
            } else {
                selection.formUnion(ids)
            }
        }
    }

    /// The toolbar that turns a lane into a batch: the system bottom toolbar,
    /// like every other bar in the app that acts on a set of rows.
    ///
    /// Send acts on the ticks when there are any and on the whole lane when
    /// there aren't, so "send all" is one tap rather than select-all then send —
    /// and it says which of the two it will do, so the tap is never a guess.
    /// Nothing goes out from here: the batch opens the compose sheet.
    @ToolbarContentBuilder
    private var sendToolbar: some ToolbarContent {
        if !targets.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Button(isAllPicked ? "Deselect All" : "Select All") {
                    withAnimation(Theme.Motion.snappy) {
                        if isAllPicked {
                            selection.removeAll()
                        } else {
                            selection = Set(targets.map(\.contact.id))
                        }
                    }
                }
            }

            // Short enough to sit beside "Send All" without truncating.
            BottomBarStatus(text: picked.isEmpty
                            ? "\(targets.count) \(lane == .waiting ? "waiting" : "new")"
                            : "\(picked.count) of \(targets.count)")

            ToolbarItem(placement: .bottomBar) {
                // Words, not the paperplane alone: the same button sends the
                // whole lane or just the ticks, and which one is the point.
                Button(sendTitle) {
                    send(picked.isEmpty ? targets : picked)
                }
                .fontWeight(.semibold)
                .contentTransition(.numericText())
                .buttonStyle(.glassProminent)
                .tint(.clay)
            }
        }
    }

    /// Says whether the tap writes the whole lane or just the ticks.
    private var sendTitle: String {
        picked.isEmpty ? "Send All" : "Send \(picked.count)"
    }

    private var isAllPicked: Bool {
        !targets.isEmpty && picked.count == targets.count
    }

    private func send(_ recipients: [(contact: Contact, company: String)]) {
        guard !recipients.isEmpty else { return }
        Haptics.press()
        sendBatch = SendBatch(recipients: recipients)
    }

    // MARK: - Bounces

    /// Contacts whose thread came back with a delivery failure. Surfaced here
    /// because the fix already exists — `is_valid` — and this is the only screen
    /// that knows the address is dead.
    ///
    /// Looked up by id, so a bounce at a company on a catalog page that hasn't
    /// been scrolled to yet (but is on Home, or was opened directly) still shows.
    private var bouncedContacts: [Contact] {
        jobStore.bouncedContacts(from: replySync).map(\.contact)
    }

    private var bounceBanner: some View {
        let contacts = bouncedContacts
        return BounceSummaryCard(count: contacts.count,
                                 message: "Gmail couldn't deliver these. Marking them invalid drops them from every send; Activity's Bounced lane shows why each one came back.") {
            pendingValidity = ValidityChange(contacts, isValid: false)
        }
        .popIn()
    }

    private func sync() async {
        await jobStore.syncReplies(using: replySync, forceFullCheck: true)
    }
}

// MARK: - Lane transition

/// The lane swap: the outgoing set fades and slides out under the incoming one,
/// which arrives from the side of the segment just picked.
///
/// It used to blur the whole lane as it went. A blur over a screenful of cards
/// is an offscreen render per frame — the swap stuttered on long lanes — and the
/// system's own page changes don't do it.
private struct GlassSwap: ViewModifier {
    /// 0 settled, 1 fully away.
    let progress: Double
    /// Which side "away" is on.
    let direction: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(1 - 0.05 * progress, anchor: .top)
            .offset(x: 34 * progress * direction)
    }
}

private extension AnyTransition {
    /// - Parameter direction: +1 when moving to a lane on the right, -1 to the
    ///   left. The arriving lane comes from that side; the leaving one exits the
    ///   other way, so the pair travel together rather than crossing.
    static func glassSwap(direction: Double) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: GlassSwap(progress: 1, direction: direction),
                                 identity: GlassSwap(progress: 0, direction: direction)),
            removal: .modifier(active: GlassSwap(progress: 1, direction: -direction),
                               identity: GlassSwap(progress: 0, direction: -direction))
        )
    }
}

// MARK: - Status strip

/// The scoreboard, compressed to one strip: what went out, what came back, what
/// is still quiet, and the control for asking Gmail again.
///
/// The old hero panel put a reply-rate ring and a headline sentence above these
/// same three figures. Home's card already carries the ring, and on a screen
/// whose job is sending, a second copy of it was the largest thing on screen
/// saying the least.
private struct StatusStrip: View {
    let insights: Insights
    let sync: ReplySync
    let onSync: () -> Void

    /// The reply rate rides on the Replied caption rather than taking a shape of
    /// its own — same information, none of the furniture.
    private var repliedCaption: String {
        guard insights.totalSent > 0 else { return "Replied" }
        return "Replied · \(Int((insights.replyRate * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Metric(value: insights.totalSent, caption: "Sent", size: 24)
                MetricDivider()
                Metric(value: insights.totalReplies, caption: repliedCaption,
                       tint: .statusDone, size: 24)
                MetricDivider()
                Metric(value: insights.waitingMails.count, caption: "Waiting",
                       tint: .statusWaiting, size: 24)
            }

            Divider().overlay(Color.hairline)

            ReplySyncBar(sync: sync, onCheck: onSync)
        }
        .padding(14)
        .panel(radius: Theme.Radius.hero)
        // The bar grows a progress track while a check runs and drops it after,
        // which changes the strip's height — springing it keeps the lists below
        // from snapping into their new place.
        .animation(Theme.Motion.bouncy, value: sync.isSyncing)
    }
}

// MARK: - Rows

/// The tick that says whether a row is in the next batch. Clay when it's on,
/// because clay is what the Send button is.
///
/// `isPartial` is for a company header standing over a mix of ticked and
/// unticked people: a full tick there would claim the whole company is going
/// out, and an empty one would hide that any of it is.
private struct SelectMark: View {
    let isSelected: Bool
    let isEnabled: Bool
    var isPartial = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: isSelected)
            .animation(Theme.Motion.pop, value: isSelected)
            .animation(Theme.Motion.pop, value: isPartial)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if !isEnabled { return "slash.circle" }
        if isSelected { return "checkmark.circle.fill" }
        return isPartial ? "minus.circle.fill" : "circle"
    }

    private var tint: Color {
        if !isEnabled { return .statusInvalid }
        if isSelected { return .clay }
        return isPartial ? Color.clay.opacity(0.55) : .inkFaint
    }
}

/// One person who hasn't answered. The day count is the row's headline and the
/// leading rule repeats it in colour, so the queue can be read by shape before
/// any of the numbers are.
private struct WaitingRow: View {
    let mail: Insights.WaitingMail
    let isSelected: Bool

    private var name: String {
        mail.contact.displayName
    }

    /// Silence, warming as it runs. The bands are the ones the old company cards
    /// used: a week is normal, a fortnight is late, a month is cold.
    private var heat: Color {
        switch mail.days {
        case ..<7: return .statusWaiting
        case ..<14: return .clay
        case ..<28: return .statusInvalid
        default: return .danger
        }
    }

    private var subtitle: String {
        guard mail.isMailable else { return "\(mail.company) · ruled out" }
        guard let sentAt = mail.sentAt else { return mail.company }
        return "\(mail.company) · sent \(sentAt.activityPhrase)"
    }

    var body: some View {
        HStack(spacing: 12) {
            SelectMark(isSelected: isSelected, isEnabled: mail.isMailable)

            MonogramAvatar(text: name, size: Theme.Avatar.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }
            // The words give way, not the figure: it was the figure that was
            // squeezed, into a column of single letters at large text sizes.
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: -1) {
                Text("\(mail.days)")
                    .font(.display(20, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(heat)
                Text(mail.days == 1 ? "day" : "days")
                    .font(.caption2)
                    .foregroundStyle(.inkMuted)
            }
            .fixedSize()
        }
        .padding(12)
        .opacity(mail.isMailable ? 1 : 0.6)
        .panel(accent: heat)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One company's reachable people, in a single card: a header that ticks the
/// whole company and a row per person that ticks just them.
///
/// It replaces the flat list of person cards the New lane used to be. Spread
/// out, three contacts at one company read as three unrelated decisions, and
/// mailing all of them meant three taps in three different places on the
/// screen; gathered under the name, they read as what they are — one company,
/// and a choice of how wide to go at it.
private struct CompanyGroupCard: View {
    let company: String
    /// On Home — shown with the catalog's pin, since these lead the lane.
    var isTracked = false
    let contacts: [Contact]
    let selection: Set<Contact.ID>
    let onToggleCompany: () -> Void
    let onToggleContact: (Contact.ID) -> Void

    private var pickedCount: Int { contacts.count { selection.contains($0.id) } }
    private var isWhole: Bool { !contacts.isEmpty && pickedCount == contacts.count }

    private var neverMailed: Int { contacts.count { !$0.isSent } }

    /// What this company is offering, in one line: all-new and all-overdue are
    /// worth saying outright, and a mix names the new ones because those are the
    /// ones you've never tried.
    private var summary: String {
        if pickedCount > 0 { return "\(pickedCount) of \(contacts.count) selected" }
        if neverMailed == contacts.count {
            return contacts.count == 1 ? "1 never contacted" : "\(contacts.count) never contacted"
        }
        if neverMailed == 0 { return "\(contacts.count) due for a follow-up" }
        return "\(contacts.count) to reach out · \(neverMailed) new"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggleCompany) {
                HStack(spacing: 12) {
                    SelectMark(isSelected: isWhole, isEnabled: true,
                               isPartial: pickedCount > 0)

                    MonogramAvatar(company: company, size: Theme.Avatar.small)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(company)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ink)
                                .lineLimit(1)
                            if isTracked {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.clay)
                                    .accessibilityLabel("On Home")
                            }
                        }
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(pickedCount > 0 ? Color.clay : .inkMuted)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(company)
            .accessibilityHint(isWhole ? "Deselect everyone here" : "Select everyone here")

            ForEach(contacts) { contact in
                Divider()
                    .overlay(Color.hairline)
                    .padding(.leading, 12)

                Button { onToggleContact(contact.id) } label: {
                    GroupPersonRow(contact: contact, isSelected: selection.contains(contact.id))
                }
                .buttonStyle(.plain)
            }
        }
        .panelAccented(pickedCount > 0 ? .clay : nil)
    }
}

/// One person inside a company card. Carries no company name — the card it sits
/// in is the company — so the line under the name can be their job instead.
private struct GroupPersonRow: View {
    let contact: Contact
    let isSelected: Bool

    private var name: String {
        contact.displayName
    }

    /// Never-mailed is the fact worth stating; for the rest it's how stale the
    /// last attempt is, which is what put them back on this list.
    private var badge: (text: String, tint: Color) {
        guard contact.isSent, let sentAt = contact.sentAt else { return ("New", .clay) }
        let days = Calendar.current.dateComponents([.day], from: sentAt, to: .now).day ?? 0
        return ("\(days)d ago", .inkMuted)
    }

    var body: some View {
        HStack(spacing: 12) {
            SelectMark(isSelected: isSelected, isEnabled: true)

            MonogramAvatar(text: name, size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(contact.position.isEmpty ? contact.email : contact.position)
                    .font(.caption2)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(badge.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badge.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.tint.opacity(0.14), in: Capsule())
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // A ticked row inside a card can't use the leading rule the standalone
        // cards do — the rule belongs to the card — so it says so by lifting off
        // the paper instead.
        .background(isSelected ? Color.clay.opacity(0.10) : .clear)
        .contentShape(.rect)
        .animation(Theme.Motion.pop, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A reply, with the opening line of what they said.
///
/// Fixed lines — name, company, two reserved lines of reply — so the lane is an
/// even column however much of the reply was captured.
private struct ReplyCard: View {
    let entry: ActivityEntry

    private var name: String {
        entry.contact.displayName
    }

    /// Who actually answered. A reply from a different address than the one we
    /// mailed is the normal case for a shared inbox, so it's shown rather than
    /// quietly folded into the contact's name.
    private var replierNote: String? {
        guard let from = entry.contact.replyFrom, !from.isEmpty else { return nil }
        let address = Self.address(in: from)
        guard !address.isEmpty,
              address.caseInsensitiveCompare(entry.contact.email) != .orderedSame else { return nil }
        return address
    }

    private var snippet: String? {
        entry.contact.replyPreview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MonogramAvatar(text: name, size: Theme.Avatar.small)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.statusDone, in: Circle())
                        .overlay(Circle().strokeBorder(Color.paperRaised, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let replied = entry.contact.repliedAt {
                        Text(replied.activityLabel)
                            .font(.caption2)
                            .foregroundStyle(.statusDone)
                    }
                }

                // Who actually answered rides on the company line rather than on
                // a line of its own that only some cards had.
                Text(replierNote.map { "\(entry.company) · via \($0)" } ?? entry.company)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)

                Text(snippet ?? "No preview of the reply was captured")
                    .font(.caption)
                    .foregroundStyle(snippet == nil ? Color.inkFaint : Color.ink.opacity(0.75))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .panel(accent: .statusDone)
    }

    /// Pull the bare address out of a `Name <a@b.com>` header.
    private static func address(in header: String) -> String {
        guard let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">"),
              open < close else {
            return header.trimmingCharacters(in: .whitespaces)
        }
        return String(header[header.index(after: open)..<close])
    }
}

#Preview {
    QuickActionsView()
        .environment(JobStore())
        .environment(ReplySync())
}
