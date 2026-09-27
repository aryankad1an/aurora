import SwiftUI

/// Who to mail at a handful of companies, picked by rule rather than name by
/// name — "everyone I haven't written to yet", "anyone quiet for a month".
///
/// Each rule is a card with its live head-count and a bar split by company, so
/// what a tap will send is visible before it's tapped: a rule that would mail
/// twelve people at one company and none at the others looks like it. Picking a
/// rule hands the recipients to the usual compose flow; nothing sends from here.
struct SendChooserView: View {
    let companies: [Job]
    let onChoose: (SendBatch) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    ForEach(SendAudience.allCases) { audience in
                        AudienceCard(audience: audience,
                                     picks: audience.picks(in: companies)) { recipients in
                            Haptics.press()
                            onChoose(SendBatch(title: audience.title, recipients: recipients))
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle("Send to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(companies.prefix(4)) { company in
                    MonogramAvatar(company: company.company, size: 34)
                        .overlay(RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous)
                            .strokeBorder(Color.paper, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(companies.count == 1 ? companies[0].company : "\(companies.count) companies")
                    .font(.display(18))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text("\(companies.reduce(0) { $0 + $1.validContacts.count }) people you can mail")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Presenting

/// The companies a Send is choosing recipients at. Identified, so the chooser
/// sheet keeps showing them while it animates away.
struct SendTarget: Identifiable {
    let id = UUID()
    let companies: [Job]
}

extension View {
    /// The Send flow for a multi-select of companies: the chooser while
    /// `target` is set, then — once it has gone — the compose screen for
    /// whoever was picked. `onSent` runs after the mails go, to close the
    /// selection they came from.
    func sendChooser(for target: Binding<SendTarget?>, onSent: @escaping () -> Void) -> some View {
        modifier(SendChooserFlow(target: target, onSent: onSent))
    }
}

private struct SendChooserFlow: ViewModifier {
    @Binding var target: SendTarget?
    let onSent: () -> Void

    /// Picked in the chooser, held until its sheet has dismissed so the compose
    /// sheet can take its place — two sheets can't be up at once.
    @State private var pending: SendBatch?
    @State private var batch: SendBatch?

    func body(content: Content) -> some View {
        content
            .sheet(item: $target, onDismiss: {
                batch = pending
                pending = nil
            }) { target in
                SendChooserView(companies: target.companies) { chosen in
                    pending = chosen
                    self.target = nil
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $batch) { batch in
                SendMailView(title: batch.title, recipients: batch.recipients) {
                    self.batch = nil
                    onSent()
                }
            }
    }
}

// MARK: - Rules

/// The rules a batch can be picked by. Only valid contacts with an address are
/// ever eligible — the same bar every other send in the app holds.
enum SendAudience: CaseIterable, Identifiable {
    case fresh, quiet, followUp, everyone

    var id: Self { self }

    var title: String {
        switch self {
        case .fresh: "Not mailed yet"
        case .quiet: "Quiet for a month"
        case .followUp: "Follow up the silent"
        case .everyone: "Everyone"
        }
    }

    var detail: String {
        switch self {
        case .fresh: "People you've never written to."
        case .quiet: "Never mailed, or last mailed over 30 days ago — and no reply."
        case .followUp: "Mailed over a week ago, still no answer."
        case .everyone: "Every valid contact, including people who replied."
        }
    }

    var systemImage: String {
        switch self {
        case .fresh: "sparkles"
        case .quiet: "clock.arrow.circlepath"
        case .followUp: "arrowshape.turn.up.right.fill"
        case .everyone: "person.3.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fresh: .clay
        case .quiet: .kraft
        case .followUp: .slate
        case .everyone: .olive
        }
    }

    func includes(_ contact: Contact, now: Date = .now) -> Bool {
        guard contact.isMailable else { return false }
        let sent = contact.sentAt ?? .distantPast
        switch self {
        case .fresh:
            return !contact.isSent
        case .quiet:
            return !contact.hasReplied && (!contact.isSent || sent < now.addingTimeInterval(-30 * 86_400))
        case .followUp:
            return contact.isSent && !contact.hasReplied && sent < now.addingTimeInterval(-7 * 86_400)
        case .everyone:
            return true
        }
    }

    /// The matching contacts, per company, in the companies' order.
    func picks(in companies: [Job]) -> [(company: Job, contacts: [Contact])] {
        companies.map { company in (company, company.contacts.filter { includes($0) }) }
    }
}

// MARK: - Card

private struct AudienceCard: View {
    let audience: SendAudience
    let picks: [(company: Job, contacts: [Contact])]
    let onChoose: ([(contact: Contact, company: String)]) -> Void

    private var total: Int { picks.reduce(0) { $0 + $1.contacts.count } }

    private var recipients: [(contact: Contact, company: String)] {
        picks.flatMap { pick in pick.contacts.map { ($0, pick.company.company) } }
    }

    var body: some View {
        Button { onChoose(recipients) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: audience.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(audience.tint)
                        .frame(width: 36, height: 36)
                        .background(audience.tint.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(audience.title)
                            .font(.headline)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        Text(audience.detail)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(2, reservesSpace: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(total)")
                            .font(.display(26))
                            .monospacedDigit()
                            .foregroundStyle(total == 0 ? Color.inkFaint : Color.ink)
                        Text(total == 1 ? "person" : "people")
                            .font(.caption2)
                            .foregroundStyle(.inkFaint)
                    }
                }

                // Drawn empty rather than left out when nobody qualifies, so an
                // empty audience's card is the same height as the rest.
                DistributionBar(picks: picks, total: total)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .opacity(total == 0 ? 0.5 : 1)
        }
        .buttonStyle(CardPress())
        .disabled(total == 0)
        .accessibilityLabel("\(audience.title), \(total) \(total == 1 ? "person" : "people")")
        .accessibilityHint(audience.detail)
    }
}

/// A single bar split by company, each segment in that company's own colour —
/// with the largest few named underneath, like a chart's legend.
private struct DistributionBar: View {
    let picks: [(company: Job, contacts: [Contact])]
    let total: Int

    private var segments: [(name: String, count: Int)] {
        picks.filter { !$0.contacts.isEmpty }
            .map { ($0.company.company, $0.contacts.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    if segments.isEmpty {
                        Capsule().fill(Color.hairline)
                    }
                    ForEach(segments, id: \.name) { segment in
                        Capsule()
                            .fill(Color.monogram(for: segment.name))
                            .frame(width: max(4, (geometry.size.width - CGFloat(segments.count - 1) * 2)
                                                * CGFloat(segment.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)

            Text(segments.isEmpty ? "Nobody right now"
                 : segments.prefix(3).map { "\($0.name) \($0.count)" }.joined(separator: " · ")
                 + (segments.count > 3 ? " · +\(segments.count - 3)" : ""))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.inkFaint)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}
