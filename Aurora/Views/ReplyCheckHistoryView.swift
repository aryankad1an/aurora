import SwiftUI

/// The latest reply check as a timeline, opened by tapping the status line in
/// Activity: each step on a rule, what it did once done, the one running now
/// moving, and the ones still to come greyed out. While a check runs the
/// timeline scrolls smoothly to follow it. Nothing else — one check, the
/// latest; the one before it is gone once a new one finishes.
struct ReplyCheckHistoryView: View {
    let sync: ReplySync
    /// A hard check: every open thread read in full, and notices searched
    /// across the whole window, not only what's new since the last check.
    var onCheckEverything: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var record: ReplyCheckRecord? { sync.checkLog.records.first }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let record {
                        VStack(alignment: .leading, spacing: 0) {
                            let rows = Self.rows(record, sync: sync)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                TimelineRow(row: row, isLast: index == rows.count - 1)
                                    .id(row.id)
                            }
                        }
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.vertical, 16)
                        .animation(.smooth(duration: 0.45), value: record.steps.count)
                    } else {
                        InlineEmptyState(title: "Not checked yet",
                                         systemImage: "clock",
                                         message: "Your mail is checked for replies and bounces when the app opens.")
                            .padding(.horizontal, Theme.Space.gutter)
                    }
                }
                .onAppear { follow(proxy, animated: false) }
                .onChange(of: sync.progress.step) { follow(proxy, animated: true) }
            }
            .paperScreen()
            .navigationTitle("Status")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCheckEverything {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Check Everything") {
                            Haptics.press()
                            onCheckEverything()
                        }
                        .disabled(sync.isSyncing)
                        .accessibilityHint("Reads every open thread again, not only ones with new mail")
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

    /// While a check runs, keep the step it's on in view.
    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard sync.isSyncing, sync.progress.step > 0 else { return }
        let id = ReplySync.stepTitles[sync.progress.step - 1]
        if animated {
            withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private var subtitle: String {
        guard let record else { return "" }
        if record.result == .running { return "Updating" }
        let finished = ReplySync.when(record.finishedAt ?? record.startedAt)
        switch record.result {
        case .stopped: return "Stopped at \(finished)"
        default: return "Updated \(finished)"
        }
    }

    /// One row per step: the plan, each step done, running or waiting — and,
    /// for a check that stopped, why.
    static func rows(_ record: ReplyCheckRecord, sync: ReplySync) -> [TimelineRow.Model] {
        let running = record.result == .running && sync.isSyncing
        let plan = record.plan ?? record.steps.map(\.title)
        let activeTitle = running && sync.progress.step > 0 ? ReplySync.stepTitles[sync.progress.step - 1] : nil
        var rows: [TimelineRow.Model] = plan.compactMap { title in
            if let step = record.steps.first(where: { $0.title == title }) {
                return .init(id: title, title: title, detail: step.summary, issues: step.issues, state: .done)
            }
            if title == activeTitle {
                let progress = sync.progress
                let detail = progress.total > 0
                    ? "\(min(progress.done, progress.total)) of \(progress.total) \(progress.unit)" : "Starting"
                return .init(id: title, title: title, detail: detail, state: .active(progress.fraction))
            }
            // Still to come — or, once a check is over, a step it never reached.
            return running ? .init(id: title, title: title, detail: "Waiting", state: .waiting) : nil
        }
        if case .stopped(let why) = record.result {
            rows.append(.init(id: "stopped", title: "Stopped", detail: why, state: .stopped))
        }
        return rows
    }
}

/// A step on the timeline: a marker on a rule, its title and what it did.
struct TimelineRow: View {
    struct Model: Identifiable {
        let id: String
        let title: String
        let detail: String
        var issues: [String] = []
        let state: State
    }

    enum State: Equatable {
        case done
        /// Running now, with how far it has got.
        case active(Double)
        case waiting
        case stopped
    }

    let row: Model
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker
                    .frame(width: 18, height: 18)
                if !isLast {
                    Rectangle()
                        .fill(row.state == .done ? Color.statusDone.opacity(0.5) : Color.hairline)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.state == .stopped ? Color.statusInvalid : Color.ink)
                Text(row.detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.inkMuted)
                    .contentTransition(.numericText())
                if case .active(let fraction) = row.state {
                    ProgressView(value: fraction)
                        .tint(.clay)
                        .animation(.smooth, value: fraction)
                        .padding(.top, 4)
                }
                ForEach(row.issues, id: \.self) { issue in
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.kraft)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, isLast ? 0 : 22)
        }
        // Steps still to come sit greyed out until their turn.
        .opacity(row.state == .waiting ? 0.4 : 1)
        .animation(.smooth(duration: 0.4), value: row.state)
    }

    @ViewBuilder
    private var marker: some View {
        switch row.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(row.issues.isEmpty ? Color.statusDone : Color.kraft)
        case .active:
            Image(systemName: "circle.dotted")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.clay)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .waiting:
            Circle()
                .strokeBorder(Color.inkFaint, lineWidth: 2)
                .frame(width: 14, height: 14)
        case .stopped:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.statusInvalid)
        }
    }
}
