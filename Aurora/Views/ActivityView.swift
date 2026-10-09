import SwiftUI

/// The Activity tab: every mail, from the moment it's queued to the answer.
///
/// Four lanes, in the order a mail moves through them:
///
/// - **Queued** — the mail queue: sending, paused, ready, scheduled and just
///   finished, with every control the queue has (the shelf and the Live
///   Activity open this lane);
/// - **Sent** — every mail sent, hung off a time axis and grouped by day;
/// - **Replied** — the ones answered, in the order the answers came;
/// - **Bounced** — mail that came back, to fix or rule out.
///
/// Search narrows every lane; the strip above says when Gmail was last read
/// for replies and asks it again on demand. Any sent mail can be checked for a
/// bounce on its own, from its menu or its page.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore
    /// Activity is where a user goes *looking* for an answer, so it owns a way to
    /// ask Gmail for one rather than waiting on the launch/foreground sync.
    @Environment(ReplySync.self) private var replySync

    enum Lane: Hashable { case queued, sent, replied, bounced }

    @State private var lane: Lane = .sent
    @State private var searchText = ""
    @State private var summaryItem: ActivityEntry?
    /// A Mark Invalid from the Bounced lane, held until it's confirmed.
    @State private var pendingValidity: ValidityChange?
    /// A bounced contact opened from the lane, to fix or rule out.
    @State private var openBounce: BouncedContact?
    /// The timeline of reply checks, opened from the status line.
    @State private var showsCheckHistory = false
    @Environment(MailQueue.self) private var mailQueue
    /// A batch opened from a queue lane.
    @State private var openBatch: UUID?
    /// A batch with mail still to go, waiting on a confirm to be removed.
    @State private var removingBatch: MailBatch?
    @State private var clearingQueue = false
    /// What a Check for Bounce found, to say in an alert.
    @State private var bounceCheck: BounceCheckResult?
    /// How many entries are built. The feed is attached 50 at a time: the next
    /// page when the end of the current one scrolls into view.
    @State private var limit = 50

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.activity.isEmpty && mailQueue.batches.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .paperScreen()
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search people, companies, subjects")
            // Asking Gmail is what this screen is for; the glyph turns for as
            // long as the check runs, however it was started.
            .topBarActions(
                TopBarPrimary(title: "Check for Replies", systemImage: "arrow.clockwise",
                              isBusy: replySync.isSyncing) {
                    Task { await checkForReplies() }
                }
            ) {
                QueueClearItems { clearingQueue = true }
                Divider()
                Picker(selection: $lane.animation(Theme.Motion.bouncy)) {
                    Label("Queued", systemImage: "tray").tag(Lane.queued)
                    Label("Sent", systemImage: "tray.full").tag(Lane.sent)
                    Label("Replied", systemImage: "arrowshape.turn.up.left").tag(Lane.replied)
                    Label("Bounced", systemImage: "exclamationmark.triangle").tag(Lane.bounced)
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease")
                }
                .pickerStyle(.inline)
            }
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company, sendID: item.id)
            }
            .navigationDestination(item: $openBatch) { id in
                BatchDetailView(batchID: id)
            }
            .queueAlerts(removing: $removingBatch, clearingAll: $clearingQueue)
            .alert(bounceCheck?.title ?? "", isPresented: Binding(get: { bounceCheck != nil },
                                                                 set: { if !$0 { bounceCheck = nil } })) {
                if bounceCheck?.bounced == true {
                    Button("Show Bounced") { withAnimation(Theme.Motion.bouncy) { lane = .bounced } }
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(bounceCheck?.message ?? "")
            }
            // The shelf, the Live Activity and notifications open the queue here.
            .task(id: mailQueue.isOpenRequested) {
                guard mailQueue.isOpenRequested else { return }
                openBatch = nil
                withAnimation(Theme.Motion.bouncy) { lane = .queued }
                mailQueue.isOpenRequested = false
            }
            .validityAlert($pendingValidity) { change in
                Task { await jobStore.markBouncedInvalid(change.ids, sync: replySync) }
            }
            .sheet(isPresented: $showsCheckHistory) {
                ReplyCheckHistoryView(sync: replySync) {
                    Task { await checkForReplies() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $openBounce) { item in
                ContactDetailView(contact: item.contact, company: item.company) { isValid in
                    Task {
                        if isValid {
                            await jobStore.setValidity([item.contact.id], isValid: true)
                        } else {
                            await jobStore.markBouncedInvalid([item.contact.id], sync: replySync)
                        }
                    }
                } onSave: { updated in
                    Task { await jobStore.updateContact(updated) }
                }
            }
        }
    }

    /// A `List`, not a `ScrollView` of a `LazyVStack`: the feed runs to hundreds
    /// of mails, and a lazy stack keeps every row it has ever built alive, where
    /// a list reuses its cells the way the system's own long feeds do.
    private var content: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = Self.feed(jobStore.activity, lane: lane, query: query)
        return List {
            // No Check Now of its own: the bar's ↻ and a pull already ask.
            ReplySyncBar(sync: replySync, onOpenHistory: { showsCheckHistory = true })
                .padding(.horizontal, 4)
                .cardRow(top: 6, bottom: 6)

            // The system's segmented control: a Liquid Glass thumb that
            // slides between the lanes.
            SegmentedSelector(segments: [
                (.queued, queuedCount > 0 ? "Queued \(queuedCount)" : "Queued"),
                (.sent, "Sent"),
                (.replied, "Replied"),
                (.bounced, bouncedCount > 0 ? "Bounced \(bouncedCount)" : "Bounced")
            ], selection: $lane)
                .cardRow(top: 4, bottom: 10)

            switch lane {
            case .queued:
                QueueLaneSections(query: query,
                                  onOpen: { openBatch = $0 },
                                  onRemove: { batch in mailQueue.remove(batch) { removingBatch = $0 } })
            case .bounced:
                BouncedLane(bounced: bounced.filter { query.isEmpty || $0.contact.matches(query) || $0.company.localizedCaseInsensitiveContains(query) },
                            total: bounced.count,
                            onOpen: { openBounce = $0 },
                            onMark: { pendingValidity = ValidityChange($0.map(\.contact), isValid: false) },
                            onDismiss: { item in
                                Haptics.tap(0.5)
                                withAnimation(Theme.Motion.snappy) { replySync.dismissBounce(item.contact.id) }
                            })
            case .sent, .replied:
                ActivityFeed(entries: entries, limit: limit,
                             isReplyOrdered: lane == .replied,
                             onOpen: { summaryItem = $0 },
                             onCheckBounce: { entry in Task { await checkBounce(entry) } },
                             onReachEnd: { limit += 50 })
            }
        }
        .cardList()
        .scrollDismissesKeyboard(.immediately)
        // A pull here means "is there anything new?", and the answer to that lives
        // in Gmail, not in the database.
        .refreshable { await checkForReplies() }
        // A new filter is a new feed: back to its first page.
        .onChange(of: lane) { limit = 50 }
        .onChange(of: query) { limit = 50 }
    }

    /// The entries in `lane` matching `query`. The store's order is newest send
    /// first — right for every lane but Replied, which is a list of answers and
    /// runs on when they arrived.
    private static func feed(_ entries: [ActivityEntry], lane: Lane, query: String) -> [ActivityEntry] {
        let matching = entries.filter { entry in
            if lane == .replied, !entry.contact.hasReplied { return false }
            guard !query.isEmpty else { return true }
            return entry.company.localizedCaseInsensitiveContains(query)
                || entry.contact.matches(query)
                || (entry.contact.sentSubject?.localizedCaseInsensitiveContains(query) ?? false)
        }
        guard lane == .replied else { return matching }
        return matching.sorted {
            ($0.contact.repliedAt ?? $0.date ?? .distantPast) > ($1.contact.repliedAt ?? $1.date ?? .distantPast)
        }
    }

    private var bounced: [BouncedContact] { jobStore.bouncedContacts(from: replySync) }
    private var bouncedCount: Int { bounced.count }

    /// Batches in the queue with mail still to go, for the lane's count.
    private var queuedCount: Int { mailQueue.batches.count(where: \.hasWork) }

    /// Look for one mail's bounce now, and say what was found.
    private func checkBounce(_ entry: ActivityEntry) async {
        Haptics.tap(0.5)
        let result = await jobStore.checkBounce(sendID: entry.id, using: replySync)
        bounceCheck = BounceCheckResult(result, name: entry.contact.displayName)
        if case .bounced = result { Haptics.thud() }
    }

    /// Ask Gmail what came back, then reload.
    private func checkForReplies() async {
        await jobStore.load()
        await jobStore.syncReplies(using: replySync)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No mail sent yet", systemImage: "paperplane")
        } description: {
            Text("Every mail you send lands here — newest first, with the exact subject and message that went out.")
        }
    }
}

// MARK: - Bounced

/// Mail that came back: a card saying what that means with Mark All as
/// Invalid, then a row per address. A row opens the contact, where a bounce
/// can be fixed, ruled out or dismissed.
private struct BouncedLane: View {
    let bounced: [BouncedContact]
    /// Before the search narrowed it.
    let total: Int
    let onOpen: (BouncedContact) -> Void
    let onMark: ([BouncedContact]) -> Void
    let onDismiss: (BouncedContact) -> Void

    var body: some View {
        if total == 0 {
            InlineEmptyState(title: "No bounced mail", systemImage: "checkmark.seal",
                             message: "When Gmail can't deliver a mail you sent, it's listed here with the reason, so you can fix the address or mark it invalid.",
                             tint: .statusDone)
                .cardRow()
        } else {
            BounceSummaryCard(count: bounced.isEmpty ? total : bounced.count,
                              message: "Gmail couldn't deliver these. Fix a typo, or mark them invalid so no one mails them again.") {
                onMark(bounced)
            }
            .cardRow(top: 0, bottom: 8)
            if bounced.isEmpty {
                InlineEmptyState(title: "Nothing here", systemImage: "line.3.horizontal.decrease",
                                 message: "No bounced address matches the search.")
                    .cardRow()
            }
            ForEach(bounced) { item in
                BounceListRow(item: item,
                              onOpen: { onOpen(item) },
                              onMark: { onMark([item]) },
                              onDismiss: { onDismiss(item) })
                    .cardRow(top: 4, bottom: 4)
                    .swipeActions(edge: .trailing) {
                        Button { onMark([item]) } label: {
                            Label("Mark Invalid", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .tint(.statusInvalid)
                    }
                    .swipeActions(edge: .leading) {
                        Button { onDismiss(item) } label: {
                            Label("Not a Bounce", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.slate)
                    }
            }
        }
    }
}

// MARK: - The feed

/// The mails, hung off a time axis and grouped by day. Built 50 at a time: the
/// next page is attached when the end of the current one scrolls into view.
///
/// Every row is a list row with no insets between them, so the time axis drawn
/// behind each one runs unbroken from row to row.
private struct ActivityFeed: View {
    let entries: [ActivityEntry]
    let limit: Int
    let isReplyOrdered: Bool
    let onOpen: (ActivityEntry) -> Void
    let onCheckBounce: (ActivityEntry) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        if entries.isEmpty {
            InlineEmptyState(title: "Nothing here", systemImage: "line.3.horizontal.decrease",
                             message: "No mail matches this lane and filter.")
                .cardRow()
        } else {
            ForEach(Self.days(entries.prefix(limit), isReplyOrdered: isReplyOrdered), id: \.day) { group in
                FeedDayHeader(day: group.day, count: group.entries.count)
                    .cardRow(top: 0, bottom: 0)
                ForEach(group.entries) { entry in
                    FeedRow(entry: entry, isReplyOrdered: isReplyOrdered) { onOpen(entry) }
                        .cardRow(top: 0, bottom: 0)
                        .contextMenu {
                            Button("Open Mail", systemImage: "envelope.open") { onOpen(entry) }
                            Button("Check for Bounce", systemImage: "arrow.uturn.backward.circle") { onCheckBounce(entry) }
                        }
                }
            }
            if entries.count > limit {
                LoadingRow()
                    .cardRow()
                    .onAppear(perform: onReachEnd)
            }
        }
    }

    private static func days(_ entries: ArraySlice<ActivityEntry>,
                             isReplyOrdered: Bool) -> [(day: Date, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [ActivityEntry]] = [:]
        for entry in entries {
            let date = isReplyOrdered ? (entry.contact.repliedAt ?? entry.date) : entry.date
            let key = date.map { calendar.startOfDay(for: $0) } ?? .distantPast
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(entry)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }
}

/// Geometry shared by the header and the rows, so the axis runs through both.
private enum FeedAxis {
    static let timeWidth: CGFloat = 52
    static let spacing: CGFloat = 10
    static let node: CGFloat = 10
    static var center: CGFloat { timeWidth + spacing + node / 2 }
}

/// A day on the axis: a label, a dashed rule, a count — like a chart's tick.
private struct FeedDayHeader: View {
    let day: Date
    let count: Int

    private var label: String {
        if day == .distantPast { return "Earlier" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.inkMuted)
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 1)
                .mask(HStack(spacing: 3) {
                    ForEach(0..<60, id: \.self) { _ in Rectangle().frame(width: 3) }
                })
            Text("\(count)")
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.inkFaint)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// One mail: its time, a node on the axis, and a card with who, where, what.
private struct FeedRow: View {
    let entry: ActivityEntry
    let isReplyOrdered: Bool
    let action: () -> Void

    private var hasReplied: Bool { entry.contact.hasReplied }

    private var time: Date? {
        isReplyOrdered ? (entry.contact.repliedAt ?? entry.date) : entry.date
    }

    private var subtitle: String {
        let parts = [entry.contact.position, entry.company].filter { !$0.isEmpty }
        return parts.isEmpty ? entry.contact.email : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FeedAxis.spacing) {
                Text(time?.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: FeedAxis.timeWidth, alignment: .trailing)
                    .padding(.top, 14)

                Circle()
                    .fill(hasReplied ? Color.olive : Color.clay)
                    .frame(width: FeedAxis.node, height: FeedAxis.node)
                    .overlay(Circle().strokeBorder(Color.paper, lineWidth: 2))
                    .padding(.top, 16)

                card
            }
            .background(alignment: .topLeading) {
                // The axis the nodes sit on.
                Rectangle()
                    .fill(Color.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: FeedAxis.center - 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(CardPress())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the mail that was sent")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.contact.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hasReplied { RepliedPill(at: entry.contact.repliedAt) }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.inkMuted)
                .lineLimit(1)
            // Exactly one third line, whatever is on file: what they said if
            // they answered, else what was sent. Each was optional and up to two
            // lines, so the feed's cards came in five different heights.
            if hasReplied, let snippet = entry.contact.replyPreview {
                HStack(spacing: 7) {
                    Capsule().fill(Color.olive).frame(width: 2.5)
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let subject = entry.contact.sentSubject, !subject.isEmpty {
                Text(subject)
                    .font(.caption)
                    .foregroundStyle(Color.ink.opacity(0.8))
                    .lineLimit(1)
            } else {
                Text("Subject not recorded")
                    .font(.caption)
                    .foregroundStyle(.inkFaint)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelAccented(hasReplied ? .olive : nil)
        .padding(.vertical, 4)
    }
}

#Preview {
    ActivityView()
        .environment(JobStore())
        .environment(ReplySync())
}

/// What a Check for Bounce found, said as an alert.
struct BounceCheckResult {
    let title: String
    let message: String
    var bounced = false

    init(_ check: ReplySync.BounceCheck, name: String) {
        switch check {
        case .bounced(let reason):
            title = "It bounced"
            message = "The mail to \(name) came back: \(reason). It's in the Bounced lane, to fix the address or mark it invalid."
            bounced = true
        case .replied:
            title = "Delivered"
            message = "\(name) answered it, so it reached them. Check for Replies records the answer."
        case .clear:
            title = "No bounce found"
            message = "Nothing in your mailbox says the mail to \(name) failed. Most bounces arrive within minutes; some servers take a day."
        case .failed(let reason):
            title = "Couldn't check"
            message = reason
        }
    }
}
