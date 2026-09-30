import SwiftUI

/// The Activity tab: every mail you've sent, hung off a time axis and grouped by
/// day, newest first.
///
/// Lanes (All · Replied · Waiting) and search narrow the feed; the strip above
/// says when Gmail was last read for replies and asks it again on demand. The
/// Bounced lane is different in kind: not sent mail but mail that came back,
/// each with a button to mark the address invalid.
struct ActivityView: View {
    @Environment(JobStore.self) private var jobStore
    /// Activity is where a user goes *looking* for an answer, so it owns a way to
    /// ask Gmail for one rather than waiting on the launch/foreground sync.
    @Environment(ReplySync.self) private var replySync

    enum Lane: Hashable { case all, replied, waiting, bounced }

    @State private var lane: Lane = .all
    @State private var searchText = ""
    @State private var summaryItem: ActivityEntry?
    /// A Mark Invalid from the Bounced lane, held until it's confirmed.
    @State private var pendingValidity: ValidityChange?
    @Environment(MailQueue.self) private var mailQueue
    /// How many entries are built. The feed is attached 50 at a time: the next
    /// page when the end of the current one scrolls into view.
    @State private var limit = 50

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.activity.isEmpty {
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
                // What hasn't gone yet lives beside what has.
                Button("Mail Queue", systemImage: "tray.and.arrow.up") { mailQueue.isShowingQueue = true }
                Divider()
                Picker(selection: $lane.animation(Theme.Motion.bouncy)) {
                    Label("All", systemImage: "tray.full").tag(Lane.all)
                    Label("Replied", systemImage: "arrowshape.turn.up.left").tag(Lane.replied)
                    Label("Waiting", systemImage: "clock").tag(Lane.waiting)
                    Label("Bounced", systemImage: "exclamationmark.triangle").tag(Lane.bounced)
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease")
                }
                .pickerStyle(.inline)
            }
            .sheet(item: $summaryItem) { item in
                MailSummaryView(contact: item.contact, company: item.company)
            }
            .validityAlert($pendingValidity) { change in
                Task { await jobStore.markBouncedInvalid(change.ids, sync: replySync) }
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
            ReplySyncBar(sync: replySync)
                .padding(.horizontal, 4)
                .cardRow(top: 6, bottom: 6)

            SegmentedSelector(segments: [
                (.all, "All"),
                (.replied, "Replied"),
                (.waiting, "Waiting"),
                (.bounced, bouncedCount > 0 ? "Bounced \(bouncedCount)" : "Bounced")
            ], selection: $lane)
                .cardRow(top: 4, bottom: 10)

            if lane == .bounced {
                BouncedLane(bounced: bounced.filter { query.isEmpty || $0.contact.matches(query) || $0.company.localizedCaseInsensitiveContains(query) },
                            total: bounced.count,
                            onOpen: { summaryItem = ActivityEntry(id: $0.contact.id, company: $0.company, contact: $0.contact) },
                            onMark: { pendingValidity = ValidityChange($0.map(\.contact), isValid: false) },
                            onDismiss: { item in
                                Haptics.tap(0.5)
                                withAnimation(Theme.Motion.snappy) { replySync.dismissBounce(item.contact.id) }
                            })
            } else {
                ActivityFeed(entries: entries, limit: limit,
                             isReplyOrdered: lane == .replied,
                             onOpen: { summaryItem = $0 },
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
            switch lane {
            case .all, .bounced: break
            case .replied: guard entry.contact.hasReplied else { return false }
            case .waiting: guard !entry.contact.hasReplied else { return false }
            }
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

    /// Ask Gmail what came back, then reload.
    private func checkForReplies() async {
        await jobStore.load()
        await jobStore.syncReplies(using: replySync, forceFullCheck: true)
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

/// Mail that came back: a card saying what that means with Mark All Invalid,
/// then one card per address, each with its own Mark Invalid and Not a Bounce.
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
                             message: "When Gmail can't deliver a mail you sent, it shows up here, and you can mark the address invalid so it's never mailed again.",
                             tint: .statusDone)
                .cardRow()
        } else {
            header
                .cardRow(top: 0, bottom: 8)
            if bounced.isEmpty {
                InlineEmptyState(title: "Nothing here", systemImage: "line.3.horizontal.decrease",
                                 message: "No bounced address matches the search.")
                    .cardRow()
            }
            ForEach(bounced) { item in
                BounceRow(item: item,
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.statusInvalid)
            VStack(alignment: .leading, spacing: 3) {
                Text(total == 1 ? "1 address bounced" : "\(total) addresses bounced")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                Text("Gmail couldn't deliver to these. Marking one invalid takes it out of every send, for every user. You can mark it valid again later.")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if bounced.count > 1 {
                    Button {
                        Haptics.press()
                        onMark(bounced)
                    } label: {
                        Label("Mark All \(bounced.count) Invalid", systemImage: "person.2.slash")
                            .font(.caption.weight(.semibold))
                    }
                    .filledButton(.statusInvalid)
                    .controlSize(.small)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .panel(accent: .statusInvalid)
    }
}

/// One address that bounced: who, why, when — and what to do about it.
private struct BounceRow: View {
    let item: BouncedContact
    let onOpen: () -> Void
    let onMark: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let reason = item.bounce.reason
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    MonogramAvatar(text: item.contact.displayName, size: Theme.Avatar.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.contact.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        Text([item.contact.email, item.company].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            StatusChip(text: reason.label, systemImage: reason.systemImage, color: .statusInvalid)
                            Text("Bounced " + item.bounce.at.activityPhrase)
                                .font(.caption2)
                                .foregroundStyle(.inkFaint)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                        if let snippet = item.bounce.snippet, !snippet.isEmpty {
                            Text(snippet)
                                .font(.caption2)
                                .foregroundStyle(.inkFaint)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the mail that bounced")

            HStack(spacing: 8) {
                Button {
                    Haptics.press()
                    onMark()
                } label: {
                    Label("Mark Invalid", systemImage: "person.crop.circle.badge.xmark")
                        .font(.caption.weight(.semibold))
                }
                .filledButton(.statusInvalid)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Text("Not a Bounce")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.inkMuted)
            }
        }
        .padding(14)
        .panel(accent: .statusInvalid)
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
