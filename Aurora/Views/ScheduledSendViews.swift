import SwiftUI

/// Picking when a batch goes: a few likely times up top, the full calendar
/// below. Used to schedule from the compose screen and to move a batch in the
/// queue.
struct ScheduleSendSheet: View {
    let count: Int
    var initial: Date?
    var confirmLabel = "Schedule"
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            PaperForm {
                Section {
                    ForEach(Self.suggestions(), id: \.label) { suggestion in
                        Button {
                            Haptics.tap(0.5)
                            withAnimation(Theme.Motion.snappy) { date = suggestion.date }
                        } label: {
                            HStack {
                                Label(suggestion.label, systemImage: suggestion.systemImage)
                                    .foregroundStyle(.ink)
                                Spacer()
                                Text(suggestion.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                    .font(.caption)
                                    .foregroundStyle(.inkMuted)
                                if abs(date.timeIntervalSince(suggestion.date)) < 60 {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.clay)
                                }
                            }
                        }
                    }
                }

                Section {
                    DatePicker("Send at", selection: $date, in: Self.earliest()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .tint(.clay)
                } footer: {
                    Text("At that time you'll get a notification. Tap it — or open Aurora — to see what's going and send \(count == 1 ? "it" : "all \(count)") with one tap. Nothing goes without your OK.")
                }

                if notificationsDenied {
                    Section {
                        Label("Notifications are off for Aurora, so there'll be no reminder. The batch waits in the mail queue and asks the next time you open the app.",
                              systemImage: "bell.slash")
                            .font(.footnote)
                            .foregroundStyle(.kraft)
                    }
                }
            }
            .navigationTitle(count == 1 ? "Send Later" : "Send \(count) Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        let chosen = max(date, Self.earliest())
                        Task {
                            // Asked here, the first time, where it's plain why.
                            await ScheduledMailNotifier.requestPermission()
                            onSchedule(chosen)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                date = initial.map { max($0, Self.earliest()) } ?? Self.suggestions()[0].date
                notificationsDenied = await ScheduledMailNotifier.isDenied()
            }
        }
    }

    /// A minute out: sooner than that and "later" is "now".
    private static func earliest() -> Date { Date.now.addingTimeInterval(60) }

    private struct Suggestion {
        let label: String
        let systemImage: String
        let date: Date
    }

    /// In an hour; tomorrow at nine; and the next Monday at nine — the times a
    /// cold mail is most often held for, when it's likely to be read.
    private static func suggestions() -> [Suggestion] {
        let calendar = Calendar.current
        let now = Date.now
        let inAnHour = calendar.date(bySetting: .second, value: 0, of: now.addingTimeInterval(3600)) ?? now.addingTimeInterval(3600)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                       matchingPolicy: .nextTime) ?? tomorrowMorning
        var suggestions = [
            Suggestion(label: "In an hour", systemImage: "clock", date: inAnHour),
            Suggestion(label: "Tomorrow morning", systemImage: "sunrise", date: tomorrowMorning)
        ]
        if !calendar.isDate(monday, inSameDayAs: tomorrowMorning) {
            suggestions.append(Suggestion(label: "Monday morning", systemImage: "calendar", date: monday))
        }
        return suggestions
    }
}

extension View {
    /// A scheduled batch whose time has come, shown as its summary until it's
    /// sent or put off; swiping it away is "Not Now". Attached where sheets are
    /// shown from — the root, and the queue screen while that's up, since only
    /// one sheet can be on screen at a time.
    func dueBatchSummary(isEnabled: Bool = true) -> some View {
        modifier(DueBatchSummary(isEnabled: isEnabled))
    }
}

private struct DueBatchSummary: ViewModifier {
    let isEnabled: Bool
    @Environment(MailQueue.self) private var queue

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { isEnabled ? queue.dueBatch : nil },
                                    set: { batch in
                                        if batch == nil, isEnabled, let due = queue.dueBatch { queue.snooze(due.id) }
                                    })) { batch in
            DueBatchSheet(batch: batch) {
                queue.sendNow(batch.id)
            } onLater: {
                queue.snooze(batch.id)
            }
        }
    }
}

/// A scheduled batch whose time has come: what's going, to whom, from which
/// template — and one tap to send it. Shown when its notification is tapped,
/// or when the app is opened (or already open) once it's due.
struct DueBatchSheet: View {
    let batch: MailBatch
    let onSend: () -> Void
    let onLater: () -> Void

    @Environment(GmailAuthStore.self) private var gmail

    /// Names shown before "and N more".
    private static let namesShown = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    recipients
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 8)
            }
            .paperScreen()
            .navigationTitle("Scheduled Mail")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { actions }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.title)
                    .foregroundStyle(.clay)
                    .symbolEffect(.bounce, options: .nonRepeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.title)
                        .font(.display(20))
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                    if let when = batch.scheduledFor {
                        Text("Scheduled for " + when.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                    }
                }
            }

            HStack {
                Metric(value: batch.pending, caption: batch.pending == 1 ? "mail" : "mails")
                MetricDivider()
                Metric(value: batch.companies.count, caption: batch.companies.count == 1 ? "company" : "companies")
                if batch.sent > 0 {
                    MetricDivider()
                    Metric(value: batch.sent, caption: "already sent", tint: .statusDone)
                }
            }

            Divider().overlay(Color.hairline)

            VStack(alignment: .leading, spacing: 6) {
                line("doc.text", written)
                if let from = gmail.connectedEmail {
                    line("person.crop.circle", "From \(from)")
                }
                line("timer", pace)
            }
        }
        .padding(16)
        .panel(radius: Theme.Radius.hero)
    }

    private func line(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var written: String {
        let names = batch.templateNames
        let byHand = batch.mails.count { $0.override != nil && $0.status.isWaiting }
        var text = names.isEmpty ? "" : "Written from " + names.joined(separator: ", ")
        if byHand > 0 {
            text += (text.isEmpty ? "" : " · ") + (byHand == 1 ? "1 written by hand" : "\(byHand) written by hand")
        }
        return text.isEmpty ? "Written on the compose screen" : text
    }

    /// Sends are spaced a little over a second apart.
    private var pace: String {
        let minutes = Int((Double(batch.pending) * 1.3 / 60).rounded(.up))
        return batch.pending <= 1 ? "Goes out right away"
            : "One after another, about \(minutes) minute\(minutes == 1 ? "" : "s") in all. You can keep using the app."
    }

    private var recipients: some View {
        let waiting = batch.mails.filter(\.status.isWaiting)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "To", systemImage: "person.2", count: waiting.count)
            WrappingHStack {
                ForEach(waiting.prefix(Self.namesShown)) { mail in
                    HStack(spacing: 5) {
                        MonogramAvatar(text: mail.displayName, size: 18)
                        Text(mail.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                    }
                    .padding(.leading, 3)
                    .padding(.trailing, 9)
                    .padding(.vertical, 3)
                    .background(Color.paperSunken, in: Capsule())
                }
                if waiting.count > Self.namesShown {
                    Text("and \(waiting.count - Self.namesShown) more")
                        .font(.caption)
                        .foregroundStyle(.inkMuted)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if !gmail.isConnected {
                Label("Connect Gmail in Profile to send.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.kraft)
            }
            Button {
                Haptics.cascade(batch.pending)
                onSend()
            } label: {
                Label(batch.pending == 1 ? "Send Mail" : "Send \(batch.pending) Mails", systemImage: "paperplane.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .primaryButton()
            .controlSize(.large)
            .disabled(!gmail.isConnected)

            Button("Not Now") {
                Haptics.tap(0.5)
                onLater()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.inkMuted)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Color.paper.ignoresSafeArea())
    }
}
