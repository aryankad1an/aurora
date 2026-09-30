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
        case .stopping: "Stopping…"
        case .waiting: "Next in line"
        case .paused: "Paused"
        case .due: "Ready to send"
        case .scheduled(let date): "Scheduled · " + date.formatted(date: .abbreviated, time: .shortened)
        case .finished: "Done"
        }
    }

    var systemImage: String {
        switch self {
        case .sending, .stopping: "paperplane.fill"
        case .waiting: "hourglass"
        case .paused: "pause.circle.fill"
        case .due: "bell.badge.fill"
        case .scheduled: "clock.fill"
        case .finished: "checkmark.circle.fill"
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

/// Every batch in the mail queue: what's sending, what's paused or waiting for
/// its time, and what's gone. Opened from the shelf above the tab bar, or from
/// Activity.
struct MailQueueView: View {
    @Environment(MailQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if queue.batches.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing in the queue", systemImage: "tray")
                    } description: {
                        Text("Mail you send or schedule waits here until it's gone — and comes back paused if the app closes midway.")
                    }
                } else {
                    List {
                        ForEach(ordered) { batch in
                            BatchCard(batch: batch)
                                .contentShape(.rect)
                                .onTapGesture {
                                    Haptics.tap(0.5)
                                    path.append(batch.id)
                                }
                                .cardRow(top: 6, bottom: 6)
                        }
                    }
                    .cardList()
                }
            }
            .paperScreen()
            .navigationTitle("Mail Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear Finished") {
                        Haptics.tap(0.5)
                        withAnimation(Theme.Motion.snappy) { queue.clearFinished() }
                    }
                    .disabled(!queue.batches.contains(where: \.isFinished))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BatchDetailView(batchID: id)
            }
        }
        .dueBatchSummary()
    }

    /// What needs the user first — sending, then due and paused, then what's
    /// waiting and scheduled — and what's done last, newest first.
    private var ordered: [MailBatch] {
        func rank(_ batch: MailBatch) -> Int {
            switch queue.phase(of: batch) {
            case .sending, .stopping: 0
            case .due: 1
            case .paused: 2
            case .waiting: 3
            case .scheduled: 4
            case .finished: 5
            }
        }
        return queue.batches.sorted { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            if left != right { return left < right }
            if left == 5 { return lhs.createdAt > rhs.createdAt }
            return (lhs.scheduledFor ?? lhs.createdAt) < (rhs.scheduledFor ?? rhs.createdAt)
        }
    }
}

// MARK: - Batch card

/// One batch: its name and state, how far it's got, and the one or two things
/// that can be done with it right now.
private struct BatchCard: View {
    let batch: MailBatch
    /// Set in the list, where the card opens the batch.
    var showsChevron = true

    @Environment(MailQueue.self) private var queue
    @State private var confirmingSend = false
    @State private var rescheduling = false

    var body: some View {
        let phase = queue.phase(of: batch)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: phase.systemImage)
                    .font(.title3)
                    .foregroundStyle(phase.tint)
                    .symbolEffect(.pulse, isActive: phase == .sending)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(batch.title)
                        .font(.display(17))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(phase.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phase.tint)
                    Text(counts)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.inkFaint)
                }
            }

            ProgressView(value: Double(batch.sent + batch.failed), total: Double(max(batch.mails.count, 1)))
                .tint(batch.failed > 0 ? .kraft : .statusDone)
                .animation(Theme.Motion.settle, value: batch.sent)

            actions(for: phase)
        }
        .padding(14)
        .panelAccented(phase == .due || phase == .paused ? phase.tint : nil)
        .confirmAlert(batch.pending == 1 ? "Send this mail now?" : "Send \(batch.pending) mails now?",
                      message: "They go out from your Gmail one after another, and can't be unsent.",
                      confirmLabel: "Send",
                      isPresented: $confirmingSend) {
            Haptics.cascade(batch.pending)
            queue.sendNow(batch.id)
        }
        .sheet(isPresented: $rescheduling) {
            ScheduleSendSheet(count: batch.pending, initial: batch.scheduledFor, confirmLabel: "Reschedule") { date in
                queue.reschedule(batch.id, to: date)
            }
        }
    }

    private var counts: String {
        var parts: [String] = []
        if batch.sent > 0 { parts.append("\(batch.sent) sent") }
        if batch.failed > 0 { parts.append("\(batch.failed) failed") }
        if batch.pending > 0 { parts.append("\(batch.pending) to go") }
        return parts.isEmpty ? "\(batch.mails.count) mails" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(for phase: BatchPhase) -> some View {
        HStack(spacing: 8) {
            switch phase {
            case .sending:
                action("Pause", "pause.fill") { Haptics.thud(); queue.pause(batch.id) }
            case .stopping:
                action("Pause", "pause.fill") {}.disabled(true)
            case .paused:
                action("Resume", "play.fill", prominent: true) { Haptics.press(); queue.resume(batch.id) }
                action("Later", "clock") { rescheduling = true }
            case .due:
                action("Send Now", "paperplane.fill", prominent: true) { Haptics.press(); confirmingSend = true }
                action("Later", "clock") { rescheduling = true }
            case .scheduled:
                action("Send Now", "paperplane.fill") { Haptics.press(); confirmingSend = true }
                action("Reschedule", "clock") { rescheduling = true }
            case .waiting:
                action("Pause", "pause.fill") { Haptics.thud(); queue.pause(batch.id) }
            case .finished:
                if batch.failed > 0 {
                    action("Retry Failed", "arrow.clockwise", prominent: true) { Haptics.press(); queue.retryFailed(batch.id) }
                }
            }
        }
    }

    /// A small capsule button that takes its own taps inside a tappable card.
    @ViewBuilder
    private func action(_ title: String, _ systemImage: String, prominent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        if prominent {
            Button(title, systemImage: systemImage, action: perform)
                .font(.caption.weight(.semibold))
                .filledButton()
                .controlSize(.small)
        } else {
            Button(title, systemImage: systemImage, action: perform)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.inkMuted)
        }
    }
}

// MARK: - Batch detail

/// One batch, person by person. Each mail is written only when it's opened:
/// the list shows who and where it's got to, never the text.
private struct BatchDetailView: View {
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
        return List {
            BatchCard(batch: batch, showsChevron: false)
                .cardRow(top: 6, bottom: 6)

            SavedTemplatesCard(batch: batch) { viewingTemplate = $0 }
                .cardRow(top: 6, bottom: 6)

            SegmentedSelector(segments: [
                (.all, "All"), (.waiting, "To Go"), (.sent, "Sent"), (.failed, "Failed")
            ], selection: $filter)
                .cardRow(top: 6, bottom: 8)

            ForEach(mails) { mail in
                QueuedMailRow(mail: mail, template: batch.templateName(for: mail),
                              isSending: isInFlight(mail, phase: phase))
                    .contentShape(.rect)
                    .onTapGesture {
                        Haptics.tap(0.5)
                        previewing = mail
                    }
                    .cardRow(top: 3, bottom: 3)
            }
        }
        .cardList()
        .navigationTitle(batch.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Remove", systemImage: "trash", role: .destructive) { confirmingRemove = true }
                    .disabled(phase == .sending || phase == .stopping)
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
        guard phase == .sending || phase == .stopping, case .sending = mail.status else { return false }
        return true
    }
}

/// One person in a batch, and where their mail has got to.
private struct QueuedMailRow: View {
    let mail: QueuedMail
    /// The saved template it's written from; nil when written by hand.
    let template: String?
    let isSending: Bool

    var body: some View {
        HStack(spacing: 12) {
            MonogramAvatar(text: mail.displayName, size: Theme.Avatar.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(mail.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text("\(mail.recipient) · \(mail.company)")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: template == nil ? "pencil" : "doc.text")
                    Text(template ?? "Written by hand")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(template == nil ? Color.slate : Color.inkFaint)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .panel()
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
        case .failed(let reason): "Couldn't send: \(reason)"
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
private struct SavedTemplatesCard: View {
    let batch: MailBatch
    let onOpen: (MailTemplate.ID) -> Void

    @Environment(TemplateStore.self) private var templateStore

    var body: some View {
        let used = Dictionary(grouping: batch.mails.filter { $0.override == nil }, by: \.templateID)
        let byHand = batch.mails.count { $0.override != nil }
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Saved templates", systemImage: "doc.on.doc")
            ForEach(batch.templates.keys.filter { used[$0] != nil }.sorted { name($0) < name($1) }, id: \.self) { id in
                Button {
                    Haptics.tap(0.5)
                    onOpen(id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.clay)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(id))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ink)
                            Text("\(used[id]?.count ?? 0) mail\(used[id]?.count == 1 ? "" : "s") · saved "
                                 + batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.inkMuted)
                        }
                        Spacer(minLength: 6)
                        if let change = SavedTemplateView.change(of: batch.templates[id], live: templateStore.templates.first { $0.id == id }) {
                            StatusChip(text: change, systemImage: "pencil", color: .kraft)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.inkFaint)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if byHand > 0 {
                Label(byHand == 1 ? "1 mail written by hand" : "\(byHand) mails written by hand", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }
        }
        .padding(14)
        .panel()
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
