import SwiftUI

/// Where a batch has got to, as the queue screen and the shelf say it.
enum BatchPhase: Equatable {
    case sending
    /// Pause was tapped; the mail in flight is finishing.
    case stopping
    /// In line behind the batch that's sending.
    case waiting
    case paused
    /// Its time has come; it's waiting for the user's go-ahead.
    case due
    case scheduled(Date)
    case finished

    var label: String {
        switch self {
        case .sending: "Sending"
        case .stopping: "Pausing"
        case .waiting: "Next in line"
        case .paused: "Paused"
        case .due: "Ready to send"
        case .scheduled: "Scheduled"
        case .finished: "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .sending, .stopping: "paperplane.fill"
        case .waiting: "hourglass"
        case .paused: "pause.fill"
        case .due: "bell.badge.fill"
        case .scheduled: "clock.fill"
        case .finished: "checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .sending, .stopping, .due: .clay
        case .waiting, .scheduled: .statusWaiting
        case .paused: .kraft
        case .finished: .statusDone
        }
    }

    var isRunning: Bool { self == .sending || self == .stopping }

    /// The group Activity lists it under.
    var group: QueueGroup {
        switch self {
        case .due: .due
        case .waiting: .waiting
        case .scheduled: .scheduled
        case .sending, .stopping: .sending
        case .paused: .paused
        case .finished: .finished
        }
    }

    /// Waiting on the user: the card carries a rule down its edge.
    var needsUser: Bool { self == .due || self == .paused }
}

/// How Activity groups batches inside its two queue lanes, in the order
/// they're listed.
enum QueueGroup: Int, CaseIterable, Identifiable {
    case due, waiting, scheduled, sending, paused, finished
    var id: Int { rawValue }

    var destination: QueueDestination {
        switch self {
        case .due, .waiting, .scheduled: .queued
        case .sending, .paused, .finished: .inProgress
        }
    }

    var title: String {
        switch self {
        case .due: "Ready to send"
        case .waiting: "Next in line"
        case .scheduled: "Scheduled"
        case .sending: "Sending"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }

    var systemImage: String {
        switch self {
        case .due: "bell.badge.fill"
        case .waiting: "hourglass"
        case .scheduled: "clock.fill"
        case .sending: "paperplane.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }
}

extension MailQueue {
    func phase(of batch: MailBatch) -> BatchPhase {
        if runningBatchID == batch.id { return isStopping ? .stopping : .sending }
        if batch.isFinished { return .finished }
        if batch.isPaused { return .paused }
        if batch.isDue(at: clock) { return .due }
        if batch.isScheduled(at: clock), let date = batch.scheduledFor { return .scheduled(date) }
        return .waiting
    }
}

extension MailBatch {
    /// One line under the batch's name: where it's got to, in a few words.
    func status(in phase: BatchPhase) -> String {
        let mails = pending == 1 ? "1 mail" : "\(pending) mails"
        switch phase {
        case .sending: return "Sending · \(sent + failed) of \(self.mails.count) done"
        case .stopping: return "Pausing after the mail on its way"
        case .waiting: return "Next in line · \(mails)"
        case .paused:
            if let resumeAt { return "Paused · carries on \(resumeAt.queuePhrase)" }
            return "Paused · \(pending) to go"
        case .due: return "Ready to send · \(mails)"
        case .scheduled(let date): return "\(date.queueStamp) · \(mails)"
        case .finished:
            if failed == 0 { return sent == 1 ? "Sent" : "All \(sent) sent" }
            return "\(sent) sent · \(failed) failed"
        }
    }

    /// What the user should know before anything else: why it stopped, else
    /// why mail failed. One note, so the card says one thing.
    var note: String? {
        if isPaused, let pauseReason { return pauseReason }
        guard let summary = failureSummary else { return nil }
        return failed == 1 ? summary : "\(failed) failed: \(summary)"
    }

    /// Started: something has been sent or has failed.
    var hasProgress: Bool { sent + failed > 0 }
}

extension Date {
    /// "Today, 2:20 PM", "Tomorrow, 9:00 AM", "Thu 9 Oct, 2:20 PM".
    var queueStamp: String {
        let time = formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today, \(time)" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow, \(time)" }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
    }

    /// `queueStamp` for the middle of a sentence: "queued today, 2:20 PM".
    var queuePhrase: String {
        let calendar = Calendar.current
        return calendar.isDateInToday(self) || calendar.isDateInTomorrow(self)
            ? queueStamp.prefix(1).lowercased() + queueStamp.dropFirst() : queueStamp
    }
}

/// One of Activity's queue lanes, as list rows: Queued (ready, next in line,
/// scheduled) or In Progress (sending, paused, finished) — every batch as a
/// card, grouped under the app's section labels, opening to its own screen.
///
/// Rows only: Activity owns the list, the navigation, the search and the
/// confirmations (`queueAlerts`).
struct QueueLaneSections: View {
    let destination: QueueDestination
    let query: String
    let onOpen: (UUID) -> Void
    let onRemove: (MailBatch) -> Void

    @Environment(MailQueue.self) private var queue

    var body: some View {
        let batches = Self.ordered(queue.batches).filter { batch in
            queue.phase(of: batch).group.destination == destination && matches(batch)
        }
        let grouped = Dictionary(grouping: batches) { queue.phase(of: $0).group }

        if destination == .inProgress && !batches.isEmpty {
            QueueOverview(batches: batches)
                .cardRow(top: 0, bottom: 6)
        }

        if batches.isEmpty {
            empty
                .cardRow()
        }

        ForEach(QueueGroup.allCases.filter { $0.destination == destination }) { group in
            if let items = grouped[group] {
                Section {
                    ForEach(items) { batch in
                        BatchCard(batch: batch, onRemove: { onRemove(batch) })
                            .contentShape(.rect)
                            .onTapGesture {
                                Haptics.tap(0.5)
                                onOpen(batch.id)
                            }
                            .cardRow(top: 4, bottom: 4)
                            .swipeActions(edge: .trailing) {
                                if queue.runningBatchID != batch.id {
                                    Button("Remove", systemImage: "trash") { onRemove(batch) }
                                        .tint(.danger)
                                }
                            }
                    }
                } header: {
                    header(group, count: items.count)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if !query.isEmpty {
            InlineEmptyState(title: "Nothing here", systemImage: "line.3.horizontal.decrease",
                             message: "No batch or person in it matches the search.")
        } else if destination == .queued {
            InlineEmptyState(title: "Nothing queued", systemImage: "tray",
                             message: "Mail you schedule waits here for its time, and mail behind a batch that's sending waits for its turn.")
        } else {
            InlineEmptyState(title: "Nothing sending", systemImage: "paperplane",
                             message: "Mail on its way shows here, with how far it's got — and comes back paused if the app closes midway.")
        }
    }

    /// A group's label, as every list in the app labels its groups. Finished
    /// carries its own Clear, where the things it clears are.
    private func header(_ group: QueueGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            SectionLabel(title: group.title, systemImage: group.systemImage, count: count)
            if group == .finished {
                Button("Clear") {
                    Haptics.tap(0.5)
                    withAnimation(Theme.Motion.snappy) { queue.clearFinished() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.clay)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets())
    }

    private func matches(_ batch: MailBatch) -> Bool {
        guard !query.isEmpty else { return true }
        return batch.title.localizedCaseInsensitiveContains(query)
            || batch.mails.contains { $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.company.localizedCaseInsensitiveContains(query)
                || $0.recipient.localizedCaseInsensitiveContains(query) }
    }

    /// Within each group: what's soonest first, and what's done newest first.
    static func ordered(_ batches: [MailBatch]) -> [MailBatch] {
        batches.sorted { lhs, rhs in
            if lhs.isFinished && rhs.isFinished { return lhs.createdAt > rhs.createdAt }
            return (lhs.scheduledFor ?? lhs.createdAt) < (rhs.scheduledFor ?? rhs.createdAt)
        }
    }
}

/// The queue's ways to empty itself, for Activity's ⋯ menu: smallest first.
/// Nothing here touches the batch sending right now, and nothing already sent
/// is unsent — only the queue's record of it goes, after it's written to the
/// history.
struct QueueClearItems: View {
    let onClearAll: () -> Void

    @Environment(MailQueue.self) private var queue

    var body: some View {
        let finished = queue.batches.count(where: \.isFinished)
        let failed = queue.batches.filter { $0.id != queue.runningBatchID }.reduce(0) { $0 + $1.failed }
        let clearable = queue.batches.count { $0.id != queue.runningBatchID }
        Menu("Clear Queue", systemImage: "tray.and.arrow.up") {
            Button("Clear Finished", systemImage: "checkmark.circle") {
                Haptics.tap(0.5)
                withAnimation(Theme.Motion.snappy) { queue.clearFinished() }
            }
            .disabled(finished == 0)
            Button(failed == 0 ? "Clear Failed Mails" : "Clear \(failed) Failed Mail\(failed == 1 ? "" : "s")",
                   systemImage: "exclamationmark.triangle") {
                Haptics.thud()
                withAnimation(Theme.Motion.snappy) { queue.clearFailed() }
            }
            .disabled(failed == 0)
            Divider()
            Button("Clear All…", systemImage: "trash", role: .destructive, action: onClearAll)
                .disabled(clearable == 0)
        }
        .disabled(queue.batches.isEmpty)
    }
}

extension View {
    /// The confirmations removing from the queue asks for: a batch with mail
    /// still to go, and Clear All.
    func queueAlerts(removing: Binding<MailBatch?>, clearingAll: Binding<Bool>) -> some View {
        modifier(QueueAlerts(removing: removing, clearingAll: clearingAll))
    }
}

private struct QueueAlerts: ViewModifier {
    @Binding var removing: MailBatch?
    @Binding var clearingAll: Bool

    @Environment(MailQueue.self) private var queue

    func body(content: Content) -> some View {
        content
            .uniformDeleteAlert(item: $removing,
                                title: { _ in "Remove this batch?" },
                                message: removing.map { batch in
                                    "The \(batch.pending) mail\(batch.pending == 1 ? "" : "s") still to go won't be sent. Mail already sent stays sent."
                                } ?? "",
                                confirmLabel: "Remove") { batch in
                withAnimation(Theme.Motion.snappy) { queue.remove(batch.id) }
            }
            .uniformDeleteAlert(title: "Clear the queue?",
                                message: clearAllMessage,
                                confirmLabel: "Clear All",
                                isPresented: $clearingAll) {
                withAnimation(Theme.Motion.snappy) { queue.clearAll() }
            }
    }

    private var clearAllMessage: String {
        let waiting = queue.batches.filter { $0.id != queue.runningBatchID }.reduce(0) { $0 + $1.pending }
        let base = waiting == 0
            ? "Every batch is taken out of the queue. Mail already sent stays sent."
            : "\(waiting) mail\(waiting == 1 ? "" : "s") still to go won't be sent. Mail already sent stays sent."
        return queue.isRunning ? base + " The batch sending now is left to finish." : base
    }
}

extension MailQueue {
    /// Removing a batch: at once when nothing's left to send, else after a
    /// confirm (`ask`).
    func remove(_ batch: MailBatch, ask: (MailBatch) -> Void) {
        if batch.pending > 0 {
            ask(batch)
        } else {
            Haptics.thud()
            withAnimation(Theme.Motion.snappy) { remove(batch.id) }
        }
    }
}

// MARK: - Overview

/// What's in progress in three figures — set the way the scheduled-mail sheet
/// sets its own — and how far it's got.
private struct QueueOverview: View {
    let batches: [MailBatch]

    var body: some View {
        let toGo = batches.reduce(0) { $0 + $1.pending }
        let sent = batches.reduce(0) { $0 + $1.sent }
        let failed = batches.reduce(0) { $0 + $1.failed }
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Metric(value: toGo, caption: "to go", size: 24)
                MetricDivider()
                Metric(value: sent, caption: "sent", tint: .statusDone, size: 24)
                MetricDivider()
                Metric(value: failed, caption: "failed", tint: failed > 0 ? .statusInvalid : .inkFaint, size: 24)
            }
            QueueMeter(sent: sent, failed: failed, total: toGo + sent + failed)
        }
        .padding(14)
        .panel()
        .accessibilityElement(children: .combine)
    }
}

/// How far mail has got, as one bar: sent, then failed, then what's to go.
struct QueueMeter: View {
    let sent: Int
    let failed: Int
    let total: Int
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let unit = total > 0 ? proxy.size.width / CGFloat(total) : 0
            HStack(spacing: 0) {
                Rectangle().fill(Color.statusDone).frame(width: unit * CGFloat(sent))
                Rectangle().fill(Color.statusInvalid).frame(width: unit * CGFloat(failed))
                Spacer(minLength: 0)
            }
            .background(Color.paperSunken)
            .clipShape(.capsule)
        }
        .frame(height: height)
        .animation(Theme.Motion.settle, value: sent)
        .animation(Theme.Motion.settle, value: failed)
        .accessibilityHidden(true)
    }
}

/// Sent, failed and to go, each with its colour in the meter.
private struct QueueLegend: View {
    let batch: MailBatch

    var body: some View {
        WrappingHStack(spacing: 14, lineSpacing: 4) {
            if batch.sent > 0 { item("\(batch.sent) sent", .statusDone) }
            if batch.failed > 0 { item("\(batch.failed) failed", .statusInvalid) }
            if batch.pending > 0 { item("\(batch.pending) to go", .inkFaint) }
        }
        .font(.caption)
        .foregroundStyle(.inkMuted)
        .contentTransition(.numericText())
    }

    private func item(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
    }
}

/// A batch's state as the tile beside its name, in the phase's colour.
private struct PhaseTile: View {
    let phase: BatchPhase
    let tint: Color

    var body: some View {
        IconTile(systemImage: phase.systemImage, tint: tint)
            .symbolEffect(.pulse, isActive: phase == .sending)
    }
}

/// Something the user should read: why a batch stopped, or why mail failed.
private struct QueueNote: View {
    let text: Text
    var systemImage = "exclamationmark.circle.fill"

    init(text: String, systemImage: String = "exclamationmark.circle.fill") {
        self.text = Text(text)
        self.systemImage = systemImage
    }

    init(_ text: Text, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.statusInvalid)
            text
                .foregroundStyle(Color.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paperSunken, in: .rect(cornerRadius: Theme.Radius.inner, style: .continuous))
    }
}

/// Gmail asked the run to slow down: what it said, and a countdown to the
/// retry. The same mail is tried again then; nothing has been lost.
private struct CooldownNote: View {
    let cooldown: MailQueue.Cooldown

    var body: some View {
        QueueNote(Text("Gmail asked to slow down, so nothing was sent. Trying again in \(Text(cooldown.until, style: .timer).monospacedDigit())\(cooldown.attempt > 1 ? " (wait \(cooldown.attempt) of \(MailQueue.rateLimitBackoff.count))" : "").\n\(cooldown.reason)"),
                  systemImage: "hourglass")
    }
}

extension MailBatch {
    /// The tile's colour: a finished batch with failures isn't a clean tick.
    func tint(in phase: BatchPhase) -> Color {
        phase == .finished && failed > 0 ? .statusInvalid : phase.tint
    }
}

// MARK: - Controls

/// One thing that can be done with a batch right now. The card shows the
/// first two as buttons, the batch's own screen all of them, and holding a
/// card lists them in its menu — one list, so the three never disagree.
private struct BatchControl: Identifiable {
    let title: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void
    var id: String { title }
}

extension MailQueue {
    /// What can be done with `batch` now, most likely first.
    fileprivate func controls(for batch: MailBatch, phase: BatchPhase,
                              askSend: @escaping () -> Void,
                              askLater: @escaping () -> Void) -> [BatchControl] {
        let id = batch.id
        let retryFailed = {
            Haptics.press()
            self.retryFailed(id)
        }
        let retry = BatchControl(title: "Retry Failed", systemImage: "arrow.clockwise", action: retryFailed)
        let pause = BatchControl(title: "Pause", systemImage: "pause.fill") {
            Haptics.thud()
            self.pause(id)
        }
        switch phase {
        case .sending, .waiting:
            return [pause]
        case .stopping:
            return []
        case .paused:
            return [BatchControl(title: "Resume", systemImage: "play.fill", isProminent: true) {
                Haptics.press()
                self.resume(id)
            }]
            // "Retry": beside Resume and Later, and under the failures it means.
            + (batch.failed > 0 ? [BatchControl(title: "Retry", systemImage: "arrow.clockwise", action: retryFailed)] : [])
            + [BatchControl(title: "Later", systemImage: "clock", action: askLater)]
        case .due:
            return [BatchControl(title: "Send Now", systemImage: "paperplane.fill", isProminent: true, action: askSend),
                    BatchControl(title: "Later", systemImage: "clock", action: askLater)]
        case .scheduled:
            return [BatchControl(title: "Send Now", systemImage: "paperplane.fill", action: askSend),
                    BatchControl(title: "Reschedule", systemImage: "clock", action: askLater)]
        case .finished:
            guard batch.failed > 0 else { return [] }
            return [retry]
        }
    }
}

/// A batch's buttons: equal widths in a row while every label fits whole,
/// a column when one wouldn't — never a squeezed or truncated label.
private struct BatchButtons: View {
    let controls: [BatchControl]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(controls) { button($0) }
            }
            VStack(spacing: 8) {
                ForEach(controls) { button($0) }
            }
        }
    }

    @ViewBuilder
    private func button(_ control: BatchControl) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: control.systemImage)
                .imageScale(.small)
            Text(control.title)
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)

        if control.isProminent {
            Button(action: control.action) { label }
                .filledButton()
                .controlSize(.small)
        } else {
            Button(action: control.action) { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.ink)
                .controlSize(.small)
        }
    }
}

/// The confirm before a batch is sent early, and the sheet that moves it.
private struct BatchPrompts: ViewModifier {
    let batch: MailBatch
    @Binding var confirmingSend: Bool
    @Binding var rescheduling: Bool

    @Environment(MailQueue.self) private var queue

    func body(content: Content) -> some View {
        content
            .confirmAlert(batch.pending == 1 ? "Send this mail now?" : "Send \(batch.pending) mails now?",
                          message: "They go out from your Gmail one after another, and can't be unsent.",
                          confirmLabel: "Send",
                          isPresented: $confirmingSend) {
                Haptics.cascade(batch.pending)
                SendFlight.launch(count: batch.pending)
                queue.sendNow(batch.id)
            }
            .sheet(isPresented: $rescheduling) {
                ScheduleSendSheet(count: batch.pending, initial: batch.scheduledFor, confirmLabel: "Reschedule") { date in
                    queue.reschedule(batch.id, to: date)
                }
            }
    }
}

// MARK: - Batch card

/// One batch in the queue, laid out like every other card in the app: a tile,
/// its name, one line of state — then, only when there's something to show,
/// how far it's got, why it stopped, and the two things most worth doing.
private struct BatchCard: View {
    let batch: MailBatch
    let onRemove: () -> Void

    @Environment(MailQueue.self) private var queue
    @State private var confirmingSend = false
    @State private var rescheduling = false

    var body: some View {
        let phase = queue.phase(of: batch)
        let controls = queue.controls(for: batch, phase: phase,
                                      askSend: { Haptics.press(); confirmingSend = true },
                                      askLater: { rescheduling = true })
        let cooldown = queue.cooldown?.batchID == batch.id ? queue.cooldown : nil
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if cooldown != nil {
                    IconTile(systemImage: "hourglass", tint: .kraft)
                } else {
                    PhaseTile(phase: phase, tint: batch.tint(in: phase))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(batch.title)
                        .font(.headline)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(cooldown == nil ? batch.status(in: phase)
                         : "Waiting on Gmail · \(batch.sent + batch.failed) of \(batch.mails.count) done")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.inkFaint)
            }

            // How far it got, while that's still moving. A finished batch's
            // status line already says it.
            if phase != .finished && (batch.hasProgress || phase.isRunning) {
                VStack(alignment: .leading, spacing: 8) {
                    QueueMeter(sent: batch.sent, failed: batch.failed, total: batch.mails.count)
                    QueueLegend(batch: batch)
                }
            }

            if let cooldown {
                CooldownNote(cooldown: cooldown)
            } else if let note = batch.note {
                QueueNote(text: note)
            }

            // What's up next goes by itself; its controls are a hold or a
            // tap away, rather than two buttons on every waiting card.
            if phase != .waiting && phase.group != .scheduled && !controls.isEmpty {
                BatchButtons(controls: Array(controls.prefix(2)))
            }
        }
        .padding(12)
        .panelAccented(phase.needsUser ? phase.tint : nil)
        .animation(Theme.Motion.snappy, value: phase)
        .contextMenu {
            ForEach(controls) { control in
                Button(control.title, systemImage: control.systemImage, action: control.action)
            }
            if !phase.isRunning {
                if !controls.isEmpty { Divider() }
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            }
        }
        .modifier(BatchPrompts(batch: batch, confirmingSend: $confirmingSend, rescheduling: $rescheduling))
    }
}

// MARK: - Batch detail

/// One batch, person by person. Each mail is written only when it's opened:
/// the list shows who and where it's got to, never the text.
struct BatchDetailView: View {
    let batchID: UUID

    @Environment(MailQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss

    enum Filter: Hashable { case all, waiting, sent, failed }
    @State private var filter: Filter = .all
    @State private var previewing: QueuedMail?
    @State private var confirmingRemove = false
    @State private var viewingTemplate: MailTemplate.ID?

    var body: some View {
        Group {
            if let batch = queue.batch(batchID) {
                content(batch)
            } else {
                ContentUnavailableView("Removed from the queue", systemImage: "tray")
            }
        }
        .paperScreen()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ batch: MailBatch) -> some View {
        let phase = queue.phase(of: batch)
        let mails = batch.mails.filter { mail in
            switch filter {
            case .all: true
            case .waiting: mail.status.isWaiting
            case .sent: mail.status.isSent
            case .failed: mail.status.isFailed
            }
        }
        let showsCompany = batch.companies.count > 1
        return List {
            BatchHeader(batch: batch)
                .cardRow(top: 4, bottom: 6)

            SavedTemplatesSection(batch: batch) { viewingTemplate = $0 }

            Section {
                SegmentedSelector(segments: [
                    (.all, "All"), (.waiting, "To Go"), (.sent, "Sent"),
                    (.failed, batch.failed > 0 ? "Failed \(batch.failed)" : "Failed")
                ], selection: $filter)
                    .cardRow(top: 2, bottom: 6)

                ForEach(mails) { mail in
                    QueuedMailRow(mail: mail, showsCompany: showsCompany,
                                  isSending: isInFlight(mail, phase: phase))
                        .contentShape(.rect)
                        .onTapGesture {
                            Haptics.tap(0.5)
                            previewing = mail
                        }
                        .cardRow(top: 4, bottom: 4)
                        // Taking one person out: they won't be mailed. Not for
                        // mail that's gone, or may have (cut off mid-send).
                        .swipeActions(edge: .trailing) {
                            if mail.status.isRemovable && !phase.isRunning {
                                Button("Remove", systemImage: "trash") {
                                    Haptics.thud()
                                    withAnimation(Theme.Motion.snappy) { queue.removeMails([mail.id], from: batchID) }
                                }
                                .tint(.danger)
                            }
                        }
                }

                if mails.isEmpty {
                    InlineEmptyState(title: filter == .failed ? "Nothing failed" : "Nothing here",
                                     systemImage: filter == .failed ? "checkmark.circle" : "tray")
                        .cardRow()
                }
            } header: {
                SectionLabel(title: "Mails", systemImage: "envelope.fill", count: batch.mails.count)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .cardList()
        .animation(Theme.Motion.snappy, value: batch.mails.map(\.id))
        .navigationTitle(batch.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if batch.failed > 0 {
                        Button("Retry Failed", systemImage: "arrow.clockwise") {
                            Haptics.press()
                            queue.retryFailed(batchID)
                        }
                        .disabled(phase.isRunning)
                        Button(batch.failed == 1 ? "Remove Failed Mail" : "Remove \(batch.failed) Failed Mails",
                               systemImage: "exclamationmark.triangle") {
                            Haptics.thud()
                            let failed = Set(batch.mails.filter(\.status.isFailed).map(\.id))
                            withAnimation(Theme.Motion.snappy) { queue.removeMails(failed, from: batchID) }
                        }
                        .disabled(phase.isRunning)
                        Divider()
                    }
                    Button("Remove Batch", systemImage: "trash", role: .destructive) { confirmingRemove = true }
                        .disabled(phase.isRunning)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .uniformDeleteAlert(title: batch.pending > 0 ? "Remove this batch?" : "Remove from the queue?",
                            message: batch.pending > 0
                                ? "The \(batch.pending) mail\(batch.pending == 1 ? "" : "s") still to go won't be sent. Mail already sent stays sent."
                                : "Mail already sent stays sent; only this record of the batch goes.",
                            confirmLabel: "Remove",
                            isPresented: $confirmingRemove) {
            queue.remove(batchID)
            dismiss()
        }
        .sheet(item: $previewing) { mail in
            QueuedMailPreview(mail: mail, batch: batch)
        }
        .navigationDestination(item: $viewingTemplate) { id in
            SavedTemplateView(batch: batch, templateID: id)
        }
    }

    /// The one mail being handed to Gmail right now.
    private func isInFlight(_ mail: QueuedMail, phase: BatchPhase) -> Bool {
        guard phase.isRunning, case .sending = mail.status else { return false }
        return true
    }
}

/// The top of a batch's screen, set like the scheduled-mail sheet: its state,
/// three figures, the meter, every reason it stopped or failed, and every
/// button. The name is already the screen's title, so it isn't repeated.
private struct BatchHeader: View {
    let batch: MailBatch

    @Environment(MailQueue.self) private var queue
    @State private var confirmingSend = false
    @State private var rescheduling = false

    var body: some View {
        let phase = queue.phase(of: batch)
        let tint = batch.tint(in: phase)
        let controls = queue.controls(for: batch, phase: phase,
                                      askSend: { Haptics.press(); confirmingSend = true },
                                      askLater: { rescheduling = true })
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PhaseTile(phase: phase, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase == .finished && batch.failed > 0 ? "Done, with failures" : phase.label)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(stamp(phase))
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    Metric(value: batch.sent, caption: "sent", tint: .statusDone, size: 24)
                    MetricDivider()
                    Metric(value: batch.failed, caption: "failed",
                           tint: batch.failed > 0 ? .statusInvalid : .inkFaint, size: 24)
                    MetricDivider()
                    Metric(value: batch.pending, caption: "to go", size: 24)
                }
                QueueMeter(sent: batch.sent, failed: batch.failed, total: batch.mails.count)
            }

            let reasons = batch.failureReasons
            if (batch.isPaused && batch.pauseReason != nil) || !reasons.isEmpty {
                VStack(spacing: 6) {
                    if batch.isPaused, let reason = batch.pauseReason {
                        QueueNote(text: reason, systemImage: "pause.circle.fill")
                    }
                    ForEach(reasons, id: \.reason) { item in
                        QueueNote(text: "\(item.count) failed: \(item.reason)", systemImage: "xmark.octagon.fill")
                    }
                }
            }

            if !controls.isEmpty {
                BatchButtons(controls: controls)
            }
        }
        .padding(16)
        .panel(radius: Theme.Radius.hero)
        .animation(Theme.Motion.snappy, value: phase)
        .modifier(BatchPrompts(batch: batch, confirmingSend: $confirmingSend, rescheduling: $rescheduling))
    }

    private func stamp(_ phase: BatchPhase) -> String {
        switch phase {
        case .scheduled(let date): "Goes \(date.queuePhrase)"
        case .sending: "\(batch.sent + batch.failed) of \(batch.mails.count) done"
        default: "Queued \(batch.createdAt.queuePhrase)"
        }
    }
}

/// One person in a batch, and where their mail has got to — set like a
/// contact on a company's page.
private struct QueuedMailRow: View {
    let mail: QueuedMail
    /// The batch spans companies, so each row says whose.
    let showsCompany: Bool
    let isSending: Bool

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: mail.displayName, size: Theme.Avatar.small)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(mail.displayName)
                        .font(.headline)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    if mail.override != nil {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.inkFaint)
                            .accessibilityLabel("Written by hand")
                    }
                }
                Text(showsCompany ? "\(mail.recipient) · \(mail.company)" : mail.recipient)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let reason) = mail.status {
                    Text(QueuedMail.explain(reason))
                        .font(.caption)
                        .foregroundStyle(.statusInvalid)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status
        }
        .padding(12)
        .panelAccented(mail.status.isFailed ? .statusInvalid : nil)
    }

    @ViewBuilder
    private var status: some View {
        switch mail.status {
        case .pending:
            StatusChip(text: "To go", systemImage: "clock", color: .inkMuted)
        case .sending:
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                // Cut off mid-send: it's checked in Sent mail before it's retried.
                StatusChip(text: "Checking", systemImage: "questionmark.circle", color: .kraft)
            }
        case .sent:
            StatusChip(text: "Sent", systemImage: "checkmark", color: .statusDone)
        case .failed:
            StatusChip(text: "Failed", systemImage: "exclamationmark.triangle.fill", color: .statusInvalid)
        }
    }
}

/// One queued mail, written out now — the first time its text exists.
private struct QueuedMailPreview: View {
    let mail: QueuedMail
    let batch: MailBatch

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = mail.rendered(in: batch)
        NavigationStack {
            PaperList {
                Section("To") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mail.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(mail.recipient)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                    }
                }
                Section("Status") {
                    Label(statusLine, systemImage: mail.status.isFailed ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(mail.status.isFailed ? Color.statusInvalid : Color.inkMuted)
                }
                Section("Written from") {
                    if mail.override == nil, let id = mail.templateID, let name = batch.templateName(for: mail) {
                        NavigationLink {
                            SavedTemplateView(batch: batch, templateID: id)
                        } label: {
                            Label("\(name) · saved copy", systemImage: "doc.text")
                        }
                    } else {
                        Label("Written by hand on the compose screen", systemImage: "pencil")
                            .foregroundStyle(.inkMuted)
                    }
                }
                if let text {
                    Section("Subject") {
                        Text(text.subject).textSelection(.enabled)
                    }
                    Section("Message") {
                        Text(text.body)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else {
                    Section {
                        Text("The template this mail was written from is missing.")
                            .foregroundStyle(.inkMuted)
                    }
                }
            }
            .navigationTitle(mail.override == nil ? "Mail" : "Mail · Written by Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusLine: String {
        switch mail.status {
        case .pending: "Waiting to go"
        case .sending: "Was being sent when the app closed — it's checked in Sent mail before anything else"
        case .sent(let at, _, _, let recorded):
            "Sent " + at.formatted(date: .abbreviated, time: .shortened) + (recorded ? "" : " · saving to history")
        case .failed(let reason):
            QueuedMail.explain(reason) == reason
                ? "Couldn't send: \(reason)"
                : "Couldn't send. \(QueuedMail.explain(reason))"
                    + (reason.trimmingCharacters(in: .whitespaces).hasPrefix("{") ? "" : "\nGmail said: \(reason)")
        }
    }
}

// MARK: - Saved templates

extension MailBatch {
    /// The name of the saved template `mail` is written from; nil when it was
    /// written by hand.
    func templateName(for mail: QueuedMail) -> String? {
        guard mail.override == nil, let id = mail.templateID else { return nil }
        return templates[id]?.name ?? "Missing template"
    }
}

/// The templates a batch is written from, as it saved them — each opens to the
/// exact text its mails are written from, and says when the one in Templates
/// has been changed since.
private struct SavedTemplatesSection: View {
    let batch: MailBatch
    let onOpen: (MailTemplate.ID) -> Void

    @Environment(TemplateStore.self) private var templateStore

    var body: some View {
        let used = Dictionary(grouping: batch.mails.filter { $0.override == nil }, by: \.templateID)
        let ids = batch.templates.keys.filter { used[$0] != nil }.sorted { name($0) < name($1) }
        let byHand = batch.mails.count { $0.override != nil }
        if !ids.isEmpty || byHand > 0 {
            Section {
                ForEach(ids, id: \.self) { id in
                    Button {
                        Haptics.tap(0.5)
                        onOpen(id)
                    } label: {
                        row(id, count: used[id]?.count ?? 0)
                    }
                    .buttonStyle(CardPress())
                    .cardRow(top: 4, bottom: 4)
                }
                if byHand > 0 {
                    Label(byHand == 1 ? "1 mail written by hand" : "\(byHand) mails written by hand", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .padding(.horizontal, 4)
                        .cardRow(top: 2, bottom: 4)
                }
            } header: {
                SectionLabel(title: "Written from", systemImage: "doc.on.doc.fill", count: ids.count)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func row(_ id: MailTemplate.ID, count: Int) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "doc.text.fill", size: Theme.Avatar.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(name(id))
                    .font(.headline)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text("\(count) mail\(count == 1 ? "" : "s") · saved \(batch.createdAt.activityPhrase)")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                // On a line of its own, as a company card's chips are, so it
                // never squeezes the line above.
                if let change = SavedTemplateView.change(of: batch.templates[id], live: templateStore.templates.first { $0.id == id }) {
                    StatusChip(text: change, systemImage: "pencil", color: .kraft)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.inkFaint)
        }
        .padding(12)
        .panel()
        .contentShape(.rect)
    }

    private func name(_ id: MailTemplate.ID) -> String { batch.templates[id]?.name ?? "" }
}

/// One of a batch's templates exactly as it was saved when the batch was
/// confirmed — the text every mail on it is written from, placeholders and all.
private struct SavedTemplateView: View {
    let batch: MailBatch
    let templateID: MailTemplate.ID

    @Environment(TemplateStore.self) private var templateStore

    var body: some View {
        let saved = batch.templates[templateID]
        let change = Self.change(of: saved, live: templateStore.templates.first { $0.id == templateID })
        PaperList {
            Section {
                Label("Saved " + batch.createdAt.formatted(date: .abbreviated, time: .shortened)
                      + ", when this batch was confirmed. Its mails are written from this copy as they go.",
                      systemImage: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.inkMuted)
                if let change {
                    Label(change == "Deleted since"
                          ? "Deleted from Templates since. This batch still sends the copy below."
                          : "Edited in Templates since. This batch still sends the copy below, not the new text.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.kraft)
                }
            }
            if let saved {
                Section("Subject") {
                    Text(AttributedString.placeholdersLit(in: saved.subject.isEmpty ? "No subject" : saved.subject,
                                                          font: .body.weight(.semibold)))
                        .textSelection(.enabled)
                }
                Section("Message") {
                    Text(AttributedString.placeholdersLit(in: saved.content, font: .callout.weight(.semibold)))
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(saved?.name ?? "Template")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How the template in Templates differs from the saved copy, if it does.
    static func change(of saved: MailBatch.TemplateSnapshot?, live: MailTemplate?) -> String? {
        guard let saved else { return nil }
        guard let live else { return "Deleted since" }
        return live.subject == saved.subject && live.content == saved.content ? nil : "Edited since"
    }
}
