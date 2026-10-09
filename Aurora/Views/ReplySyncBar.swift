import SwiftUI

/// The one line that says whether the reply column can be trusted: when Gmail
/// was last read ("Status updated 5 minutes ago", kept current the way Mail's
/// "Updated Just Now" is), whether a read is running ("Updating", with every
/// step and count), and — when replies can't be read — why. Tapping it opens
/// the timeline of checks (`onOpenHistory`), which says what each read and
/// what, if anything, couldn't be.
///
/// Screens used to carry their own copies of this, down to the same two
/// blocker messages, and the copies had already drifted apart.
struct ReplySyncBar: View {
    let sync: ReplySync
    /// Offers Check Now when set. Left out where the screen's own top bar
    /// already carries that verb.
    var onCheck: (() -> Void)? = nil
    /// Opens the timeline of checks when the line is tapped.
    var onOpenHistory: (() -> Void)? = nil

    /// Why the last check didn't work, if it didn't. The first two only the
    /// user can fix; the last is worth a retry.
    private var problem: (symbol: String, message: String)? {
        if sync.needsMigration {
            return ("cylinder.split.1x2.fill",
                    "Database is missing the reply columns — run the migration in the README")
        }
        if sync.needsReconnect {
            return ("lock.trianglebadge.exclamationmark.fill",
                    "Reconnect Gmail in Settings to read replies")
        }
        if let message = sync.errorMessage, !sync.isSyncing {
            return ("exclamationmark.triangle.fill", message)
        }
        return nil
    }

    private func label(now: Date) -> String {
        if sync.isSyncing {
            let summary = sync.progress.summary
            return summary.isEmpty ? "Updating" : "Updating · " + summary
        }
        guard let last = sync.lastSyncedAt else { return "Status not updated yet" }
        guard now.timeIntervalSince(last) >= 60 else { return "Status updated just now" }
        return "Status updated \(last.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        VStack(spacing: 8) {
            if sync.isSyncing && sync.progress.steps > 0 {
                ProgressView(value: sync.progress.overall)
                    .tint(.clay)
                    .transition(LiquidMaterialize(scale: 0.9, anchor: .top))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let problem {
                    Label {
                        Text(problem.message)
                            .font(.caption)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: problem.symbol).font(.caption)
                    }
                    .foregroundStyle(.statusInvalid)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption2)
                        .foregroundStyle(.inkMuted)
                        .symbolEffect(.rotate, isActive: sync.isSyncing)
                    // Re-read once a minute, so "Checked 4 minutes ago" doesn't
                    // sit on screen saying "just now" for the rest of the hour.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        // Wraps rather than truncates: every step, count and
                        // percentage of a running check stays readable.
                        Text(label(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.numericText())
                    }
                }

                Spacer(minLength: 4)

                if let onCheck {
                    Button {
                        Haptics.press()
                        onCheck()
                    } label: {
                        Text(sync.isSyncing ? "Checking" : "Check Now")
                            .font(.caption.weight(.semibold))
                    }
                    .secondaryButton()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(sync.isSyncing)
                }

                if onOpenHistory != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.inkFaint)
                }
            }
        }
        .animation(Theme.Motion.snappy, value: sync.isSyncing)
        .contentShape(.rect)
        .onTapGesture {
            guard let onOpenHistory else { return }
            Haptics.tap(0.5)
            onOpenHistory()
        }
        .accessibilityAddTraits(onOpenHistory != nil ? .isButton : [])
        .accessibilityHint(onOpenHistory != nil ? "Shows what each check of your mail did" : "")
    }
}
