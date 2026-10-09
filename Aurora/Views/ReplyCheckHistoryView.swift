import SwiftUI

/// Every recent reply check as a timeline, newest first: when it ran, how far
/// back it read, and what each step did — threads read, replies and bounces
/// found, names looked up — with what couldn't be read and why. Opened from
/// the status line at the top of Activity.
struct ReplyCheckHistoryView: View {
    let sync: ReplySync
    /// Starts a check now.
    var onCheck: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    current
                    if sync.checkLog.records.isEmpty {
                        InlineEmptyState(title: "No checks yet",
                                         systemImage: "clock.arrow.circlepath",
                                         message: "Each check of your mail for replies and bounces shows up here.")
                    } else {
                        SectionLabel(title: "Timeline", systemImage: "clock", count: sync.checkLog.records.count)
                            .padding(.top, 6)
                        ForEach(sync.checkLog.records) { record in
                            CheckCard(record: record, isLive: sync.isSyncing && record.result == .running)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle("Status Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCheck {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Check Now") {
                            Haptics.press()
                            onCheck()
                        }
                        .disabled(sync.isSyncing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap(0.5)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Where things stand: updating now, or when it last finished and where
    /// the next check will start reading.
    private var current: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconTile(systemImage: sync.isSyncing ? "arrow.trianglehead.2.clockwise.rotate.90"
                            : sync.lastSyncedAt == nil ? "clock" : "checkmark",
                         tint: sync.isSyncing ? .clay : sync.lastSyncedAt == nil ? .inkFaint : .statusDone,
                         size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.isSyncing ? "Updating" : headline)
                        .font(.headline)
                        .foregroundStyle(.ink)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if sync.isSyncing {
                ProgressView(value: sync.progress.overall)
                    .tint(.clay)
                Text(sync.progress.summary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var headline: String {
        guard let last = sync.lastSyncedAt else { return "Not updated yet" }
        return "Updated " + last.formatted(.relative(presentation: .named))
    }

    private var detail: String {
        if sync.isSyncing { return "Reading your mail for replies, bounces and names." }
        var lines: [String] = []
        if let last = sync.lastSyncedAt { lines.append("Last updated \(ReplySync.when(last)).") }
        if let from = sync.checkpoint.readFrom(fullCheck: false) {
            lines.append("The next check reads mail since \(ReplySync.when(from)).")
        } else {
            lines.append("The next check reads all your open threads.")
        }
        return lines.joined(separator: " ")
    }
}

/// One check: when, how far back, how it ended, then each step on a rule.
private struct CheckCard: View {
    let record: ReplyCheckRecord
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReplySync.when(record.startedAt))
                        .font(.headline)
                        .foregroundStyle(.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(resultLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .fixedSize()
            }

            if !record.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(record.steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, isLast: index == record.steps.count - 1 && !isLive)
                    }
                }
            }
            if case .stopped(let why) = record.result {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.statusInvalid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let readFrom = record.readFrom {
            parts.append("Mail since \(ReplySync.when(readFrom))")
        } else {
            parts.append("Everything")
        }
        if let duration = record.duration {
            parts.append(Duration.seconds(duration.rounded())
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }

    private var resultLabel: String {
        switch record.result {
        case .running: "Updating"
        case .complete: "Complete"
        case .incomplete: "Some unread"
        case .stopped: "Stopped"
        }
    }

    private var symbol: String {
        switch record.result {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .complete: "checkmark.circle.fill"
        case .incomplete: "exclamationmark.circle.fill"
        case .stopped: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch record.result {
        case .running: .clay
        case .complete: .statusDone
        case .incomplete: .kraft
        case .stopped: .statusInvalid
        }
    }
}

/// A step on the card's timeline: a dot on a rule, its title, what it did,
/// and anything that went wrong.
private struct StepRow: View {
    let step: ReplyCheckRecord.Step
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(step.issues.isEmpty ? Color.inkFaint : Color.kraft)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ink)
                Text(step.summary)
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                ForEach(step.issues, id: \.self) { issue in
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.kraft)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}
