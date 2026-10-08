import SwiftUI

/// One request to open the compose screen for a batch, so `.sheet(item:)` builds
/// a fresh `SendMailView` per batch.
struct SendBatch: Identifiable {
    let id = UUID()
    /// What the compose screen is titled — which group this is.
    var title = "Send to All"
    let recipients: [(contact: Contact, company: String)]
}

/// The compose screen: every mail that's about to go out, as it will read.
///
/// Who it goes to is decided before this screen opens — a contact's send button,
/// a selection, a Quick Actions lane, the Send chooser — so it doesn't ask
/// again. It used to: a template picker over a tickable recipient list, then
/// Next to a separate review deck, then Send. That was three screens' worth of
/// deciding for one decision that's left, which is *what to say*.
///
/// So it's one screen, laid out like the thing being made:
///
/// - an **envelope** — from, and to whom (fixed, one chip per person);
/// - a **shelf of templates** — tap one and every letter below re-writes itself;
/// - the **letters** themselves, a deck you swipe through, each exactly as it
///   will be sent, each editable, each flagging any placeholder it left blank;
/// - one **Send** button, which says what's in the way when something is, and
///   beside it a clock, to send later instead.
///
/// A letter is only written when it's drawn. Each one holds its person and the
/// template it's written from (or the words it was rewritten with by hand), and
/// the deck writes the few that are on screen — so picking a template for a
/// batch of hundreds writes nothing at all. The queue does the same: the mails
/// themselves are written one by one, as they go (see `MailBatch`).
///
/// Shared by the per-company send (`init(job:preselect:)`) and every
/// cross-company batch (`init(title:recipients:onSent:)`).
struct SendMailView: View {
    let title: String
    /// Called instead of the local `dismiss()` once the mails are queued, so the
    /// presenter can also close whatever selection they came from.
    var onSent: (() -> Void)?

    @Environment(TemplateStore.self) private var templateStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(JobStore.self) private var jobStore
    @Environment(GmailAuthStore.self) private var gmail
    @Environment(MailQueue.self) private var mailQueue
    @Environment(\.dismiss) private var dismiss

    /// Everyone picked who can be mailed — all of them, however many. The
    /// queue sends them one after another, spaced out, so a big batch needs no
    /// cap here; the deck only draws the letters near the one on show.
    private let recipients: [(contact: Contact, company: String)]

    /// The mails as they stand — who, from which template or rewritten by hand
    /// — and what the screen says about them.
    @State private var batch = LetterBatch()
    /// People left out because a batch in the queue is already going to mail them.
    @State private var alreadyQueued = 0
    @State private var scheduling = false
    /// The template the whole batch was last written from. Individual letters can
    /// be moved onto another one from their own menu.
    @State private var templateID: MailTemplate.ID?
    /// The letter the deck is showing.
    @State private var focus = DeckFocus()
    /// How tall every letter is drawn: the longest one's height (see `deckSizer`).
    @State private var deckHeight: CGFloat = 0
    @State private var editing: MailPreview?
    /// A template tap that would overwrite hand edits, held until confirmed.
    @State private var pendingTemplate: MailTemplate?
    @State private var confirmingSend = false
    /// The company each one-company template was written for (see
    /// `MailTemplate.writtenFor`), worked out once per template list.
    @State private var templateCompany: [MailTemplate.ID: String] = [:]
    /// The template the last batch went out with, so the next compose starts
    /// there rather than on whichever template sorts first.
    @AppStorage("compose.lastTemplateID") private var lastTemplateID = ""

    init(title: String = "New Mail",
         recipients: [(contact: Contact, company: String)],
         onSent: (() -> Void)? = nil) {
        self.title = title
        // The same bar every send in the app holds: a real address, not ruled out.
        self.recipients = recipients.filter(\.contact.isMailable)
        self.onSent = onSent
    }

    /// - Parameter preselect: who to write to. When nil, everyone here not yet
    ///   mailed.
    init(job: Job, preselect: Set<Contact.ID>? = nil) {
        let picked = preselect.map { ids in job.contacts.filter { ids.contains($0.id) } }
            ?? job.contacts.filter { !$0.isSent }
        self.init(title: job.company, recipients: picked.map { ($0, job.company) })
    }

    private var templates: [MailTemplate] { templateStore.templates }

    private var letters: [MailPreview] { batch.letters }
    private var tally: LetterBatch.Tally { batch.tally }

    private var companyCount: Int { tally.companies.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    envelope
                    templateShelf
                    deck
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .paperScreen()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(tally.anyEdited,
                              message: "The mails you edited by hand won't be kept.")
            .safeAreaInset(edge: .bottom) { sendBar }
            .sheet(item: $editing) { letter in
                MailEditorView(letter: letter, face: batch.face(of: letter)) { subject, body in
                    apply(id: letter.id, subject: subject, body: body)
                }
            }
            .sheet(isPresented: $scheduling) {
                ScheduleSendSheet(count: letters.count, confirmLabel: "Schedule") { date in
                    schedule(for: date)
                }
            }
            .alert("Replace your edits?",
                   isPresented: Binding(get: { pendingTemplate != nil },
                                        set: { if !$0 { pendingTemplate = nil } }),
                   presenting: pendingTemplate) { template in
                Button("Cancel", role: .cancel) {}
                Button("Use “\(template.name)”", role: .destructive) {
                    write(template, to: Set(letters.map(\.id)))
                }
            } message: { _ in
                Text("Mails you've changed by hand will be rewritten from the template.")
            }
            .confirmAlert(letters.count == 1 ? "Send this mail now?" : "Send \(letters.count) mails now?",
                          message: sendConfirmation,
                          confirmLabel: "Send",
                          isPresented: $confirmingSend) { send() }
            .onAppear(perform: start)
            // Templates can arrive after the screen does (a cold start, a pull
            // on another device); the first one to land writes the letters, and
            // an edit to one shows in every letter written from it.
            .onChange(of: templates) { start() }
        }
    }

    // MARK: - Envelope

    /// From and To, set like the head of a letter. The To line is fixed: the
    /// people were chosen on the screen this one was opened from.
    private var envelope: some View {
        VStack(alignment: .leading, spacing: 0) {
            envelopeLine("From") {
                if let email = gmail.connectedEmail {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                } else {
                    Label("Gmail isn't connected — connect it in Profile", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.kraft)
                        .lineLimit(2)
                }
            }

            Divider().overlay(Color.hairline).padding(.leading, 64)

            envelopeLine("To", alignsToChips: letters.count > 1) {
                if letters.isEmpty {
                    Text("Nobody here can be mailed")
                        .font(.subheadline)
                        .foregroundStyle(.inkFaint)
                } else if let only = letters.first, letters.count == 1 {
                    // One person: their name and address, as Mail's header has
                    // it. A lone chip only repeated the letter card below.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(only.name)
                            .font(.subheadline)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        Text(only.email)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        RecipientStrip(batch: batch, focus: focus)
                        Text("\(letters.count) people" + (companyCount > 1 ? " · \(companyCount) companies" : ""))
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                    }
                }
            }

            if alreadyQueued > 0 {
                Divider().overlay(Color.hairline).padding(.leading, 64)
                Label(alreadyQueued == 1
                      ? "1 person is already in the mail queue, so they're left out"
                      : "\(alreadyQueued) people are already in the mail queue, so they're left out",
                      systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.kraft)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .panel()
        .padding(.horizontal, Theme.Space.gutter)
    }

    /// - Parameter alignsToChips: set when the line opens with a row of chips,
    ///   which has no text baseline — the label then centres on the chips
    ///   instead of dropping to the caption under them.
    private func envelopeLine<Content: View>(_ label: String, alignsToChips: Bool = false,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignsToChips ? .top : .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.inkFaint)
                .frame(width: 40, alignment: .leading)
                .padding(.top, alignsToChips ? 8 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Templates

    /// The templates as a shelf of small cards. The one every letter is written
    /// from is lit; tapping another re-writes them all at once.
    private var templateShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Template", systemImage: "doc.text", count: templates.isEmpty ? nil : templates.count)
                .padding(.horizontal, Theme.Space.gutter)

            if templates.isEmpty {
                InlineEmptyState(title: "No templates yet",
                                 systemImage: "doc.text",
                                 message: "Write one in the Templates tab — it fills in each person's name, role and company for you.")
                    .padding(.horizontal, Theme.Space.gutter)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(templates) { template in
                            templateTile(template)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Theme.Space.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func templateTile(_ template: MailTemplate) -> some View {
        let count = tally.perTemplate[template.id, default: 0]
        let isAll = !letters.isEmpty && count == letters.count
        let isSome = count > 0 && !isAll
        return Button {
            choose(template)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.display(15))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isAll {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.clay)
                            .transition(.scale.combined(with: .opacity))
                    } else if isSome {
                        // Some letters were moved onto this one individually.
                        Text("\(count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.clay)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.clay.opacity(0.14), in: Capsule())
                    }
                }
                Text(template.subject.isEmpty ? "No subject" : template.subject)
                    .font(.caption)
                    .foregroundStyle(template.subject.isEmpty ? Color.inkFaint : Color.inkMuted)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                // Always a line, so the tiles stay one height.
                Label(templateCompany[template.id].map { "Written for \($0)" } ?? "For any company",
                      systemImage: templateCompany[template.id] == nil ? "building.2" : "building.2.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isMismatched(template) ? Color.kraft : Color.inkFaint)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 176, alignment: .leading)
            .background(isAll ? Color.clay.opacity(0.10) : Color.paperRaised,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isAll ? Color.clay : Color.hairline, lineWidth: isAll ? 1.5 : 1)
            }
            .animation(Theme.Motion.pop, value: isAll)
        }
        .buttonStyle(CardPress())
        .accessibilityAddTraits(isAll ? .isSelected : [])
    }

    // MARK: - Letters

    @ViewBuilder
    private var deck: some View {
        if !letters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(title: letters.count == 1 ? "Mail" : "Mails", systemImage: "envelope")
                    Spacer()
                    if letters.count > 1 {
                        DeckCounter(letters: letters, focus: focus)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)

                // Each card is written here, as it's drawn — only the few near
                // the one on show ever are.
                DeckScroller(letters: letters, focus: focus) { letter in
                    LetterCard(letter: letter,
                               face: batch.face(of: letter),
                               minHeight: deckHeight,
                               onEdit: { editing = letter }) {
                        letterMenu(letter)
                    }
                }
                .background(alignment: .topLeading) { deckSizer }

                if letters.count > 1 && letters.count <= 16 {
                    PageDots(batch: batch, focus: focus)
                }
            }
        }
    }

    /// The deck is lazy — only the letters near the one on show exist, which is
    /// what keeps a batch of a hundred and more smooth — so it can no longer
    /// size itself by drawing every letter. Instead the longest is laid out
    /// once, unseen, at a card's width, and every card takes its height: the
    /// deck still doesn't change height under the finger as it's swiped.
    @ViewBuilder
    private var deckSizer: some View {
        if let longest = tally.longestID.flatMap({ id in letters.first { $0.id == id } }) {
            LetterCard(letter: longest, face: batch.face(of: longest), onEdit: {}) {
                EmptyView()
            }
            .padding(.leading, Theme.Space.gutter)
            .padding(.trailing, Theme.Space.gutter + (letters.count > 1 ? deckPeek : 0))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deckHeight = $0 }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func letterMenu(_ letter: MailPreview) -> some View {
        Button("Edit Mail", systemImage: "square.and.pencil") { editing = letter }
        if !templates.isEmpty {
            Menu("Use Template", systemImage: "doc.text") {
                ForEach(templates) { template in
                    Button(template.name) {
                        Haptics.press()
                        write(template, to: [letter.id])
                    }
                }
            }
            if companyCount > 1 {
                Menu("Use Template for \(letter.company)", systemImage: "building.2") {
                    ForEach(templates) { template in
                        Button(template.name) {
                            Haptics.press()
                            write(template, to: Set(letters.filter { $0.company == letter.company }.map(\.id)))
                        }
                    }
                }
            }
        }
        if letters.count > 1 {
            Divider()
            Button("Leave Out of This Send", systemImage: "minus.circle", role: .destructive) {
                leaveOut(letter)
            }
        }
    }

    // MARK: - Send

    /// What's stopping the send, in words — shown above the button rather than
    /// leaving a greyed-out button to explain itself.
    private var blocker: String? {
        if letters.isEmpty {
            return alreadyQueued > 0 ? "Everyone here is already in the mail queue." : "Nobody here can be mailed."
        }
        if !gmail.isConnected { return "Connect Gmail in Profile to send." }
        if templates.isEmpty && letters.allSatisfy({ $0.templateID == nil && !$0.isEdited }) {
            return "Write a template first."
        }
        let unwritten = tally.unwritten
        if unwritten > 0 {
            return unwritten == 1 && letters.count == 1
                ? "This mail has no subject."
                : "\(unwritten) of \(letters.count) mails have no subject."
        }
        return nil
    }

    /// Blanks don't block — a missing role often reads fine — but they're
    /// counted here, where they're the last thing seen before sending.
    private var blankCount: Int { tally.blanks }

    /// Mails written from a template meant for another company. Not a blocker
    /// — the text may have been fixed by hand — but it's the first warning.
    private var mismatchCount: Int { tally.mismatched }

    /// Whether picking `template` would write mails naming the wrong company.
    private func isMismatched(_ template: MailTemplate) -> Bool {
        guard let company = templateCompany[template.id] else { return false }
        return tally.companies.contains { $0 != company }
    }

    private var sendConfirmation: String {
        var message = letters.count == 1
            ? "It goes out from your Gmail and can't be unsent."
            : "They go out from your Gmail one after another, and can't be unsent. You can keep using the app while they do."
        if mismatchCount > 0 {
            message += mismatchCount == 1
                ? " One of them was written for a different company."
                : " \(mismatchCount) of them were written for a different company."
        }
        return message
    }

    private var sendTitle: String {
        if letters.count == 1, let only = letters.first {
            return "Send to \(only.name.split(separator: " ").first.map(String.init) ?? only.name)"
        }
        return "Send \(letters.count) Mails"
    }

    private var sendBar: some View {
        VStack(spacing: 8) {
            if let blocker {
                Label(blocker, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.kraft)
                    .transition(.opacity)
            } else if mismatchCount > 0 {
                Label(mismatchCount == 1 && letters.count == 1
                      ? "This template was written for another company"
                      : "\(mismatchCount) mail\(mismatchCount == 1 ? " was" : "s were") written for another company",
                      systemImage: "building.2.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.kraft)
                    .transition(.opacity)
            } else if blankCount > 0 {
                Label(blankCount == 1 && letters.count == 1
                      ? "A placeholder in this mail is blank"
                      : "\(blankCount) mail\(blankCount == 1 ? " has" : "s have") a blank placeholder",
                      systemImage: "circle.dashed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.inkMuted)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                // Always asks, even for one: a mail that's gone can't be taken back.
                Button {
                    Haptics.press()
                    confirmingSend = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                            .symbolEffect(.bounce, value: letters.count)
                        Text(sendTitle)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                }
                .primaryButton()

                Button {
                    Haptics.tap()
                    scheduling = true
                } label: {
                    Image(systemName: "clock")
                        .fontWeight(.semibold)
                }
                .secondaryButton()
                .accessibilityLabel("Send Later")
            }
            .controlSize(.large)
            .disabled(blocker != nil)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            // The letters scroll away under the button rather than behind a
            // hard edge.
            // Opaque by the time the warning line starts, so it never sits
            // on top of the letter text it's warning about.
            LinearGradient(stops: [.init(color: Color.paper.opacity(0), location: 0),
                                   .init(color: Color.paper.opacity(0.95), location: 0.3),
                                   .init(color: Color.paper, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .animation(Theme.Motion.snappy, value: blocker)
        .animation(Theme.Motion.pop, value: letters.count)
    }

    // MARK: - Actions

    /// Set every letter on the first template, once there is one. Runs again if
    /// the templates change — new ones arriving, or one edited — but only ever
    /// re-picks the template when nothing has been chosen or written by hand.
    private func start() {
        let tracked = jobStore.jobs.map(\.company)
        templateCompany = templates.reduce(into: [:]) { result, template in
            result[template.id] = template.writtenFor(amongst: tracked)
        }
        batch.parsed = Dictionary(uniqueKeysWithValues: templates.map { template in
            (template.id, ParsedTemplate(template, writtenFor: templateCompany[template.id]))
        })
        guard letters.isEmpty || (templateID == nil && !tally.anyEdited) else { return }
        let template = templateID.flatMap { id in templates.first { $0.id == id } } ?? defaultTemplate
        templateID = template?.id
        let profile = profileStore.profile
        // Someone a queued batch will already mail isn't written to twice.
        let queued = mailQueue.waitingContactIDs
        let fresh = recipients.filter { !queued.contains($0.contact.id) }
        alreadyQueued = recipients.count - fresh.count
        batch.letters = fresh.map { contact, company in
            MailPreview(contact: contact, company: company,
                        context: MailContext.make(contact: contact, company: company, profile: profile),
                        templateID: template?.id)
        }
        if focus.id == nil { focus.id = letters.first?.id }
    }

    /// What a fresh batch is written from: the template written for this very
    /// company when there is one (everyone here works there), then the one the
    /// last batch went out with, then the first meant for anyone — never,
    /// silently, one written for somebody else.
    private var defaultTemplate: MailTemplate? {
        let companies = Set(recipients.map(\.company))
        if companies.count == 1, let company = companies.first,
           let own = templates.first(where: { templateCompany[$0.id] == company }) {
            return own
        }
        if let last = templates.first(where: { $0.id.uuidString == lastTemplateID }),
           templateCompany[last.id].map({ companies == [$0] }) ?? true {
            return last
        }
        return templates.first { templateCompany[$0.id] == nil } ?? templates.first
    }

    /// A template tap from the shelf. Hand edits are only ever overwritten on
    /// purpose, so if there are any this asks first.
    private func choose(_ template: MailTemplate) {
        Haptics.press()
        if tally.anyEdited && template.id != templateID {
            pendingTemplate = template
        } else {
            write(template, to: Set(letters.map(\.id)))
        }
    }

    /// Put the given letters on `template`, replacing any hand edits. Nothing is
    /// written: each letter says which template it's on, and is written from it
    /// when it's drawn.
    private func write(_ template: MailTemplate, to ids: Set<MailPreview.ID>) {
        var moved = letters
        for index in moved.indices where ids.contains(moved[index].id) {
            moved[index].templateID = template.id
            moved[index].override = nil
        }
        withAnimation(Theme.Motion.snappy) {
            batch.letters = moved
            if ids.count == moved.count { templateID = template.id }
        }
    }

    /// Keep a hand edit as the letter's own words. The letter has been read and
    /// written by a person now, so its blanks stop being flagged and whatever
    /// company it names is on purpose.
    private func apply(id: MailPreview.ID, subject: String, body: String) {
        guard let index = letters.firstIndex(where: { $0.id == id }) else { return }
        batch.letters[index].override = QueuedMail.Override(subject: subject, body: body)
    }

    private func leaveOut(_ letter: MailPreview) {
        Haptics.thud()
        guard let index = letters.firstIndex(where: { $0.id == letter.id }) else { return }
        let next = letters.indices.contains(index + 1) ? letters[index + 1].id : letters[max(0, index - 1)].id
        withAnimation(Theme.Motion.snappy) {
            batch.letters.remove(at: index)
            focus.id = letters.contains { $0.id == next } ? next : letters.first?.id
        }
    }

    /// Hand the letters to the background queue and get out of the way. Exactly
    /// what's on screen goes out, hand edits included.
    private func send() {
        guard !letters.isEmpty else { return }
        // A rising run, one beat per mail. Sending eight shouldn't feel identical
        // to sending one, and this is the last moment the user is still holding
        // the phone waiting to find out that it worked.
        Haptics.cascade(letters.count)
        mailQueue.enqueue(makeBatch(scheduledFor: nil))
        finish()
    }

    private func schedule(for date: Date) {
        guard !letters.isEmpty else { return }
        Haptics.success()
        mailQueue.enqueue(makeBatch(scheduledFor: date))
        finish()
    }

    private func finish() {
        if let templateID { lastTemplateID = templateID.uuidString }
        if let onSent { onSent() } else { dismiss() }
    }

    /// The batch as the queue keeps it: the templates in use, copied as they
    /// read now, and each person with what fills their placeholders. The mails
    /// themselves are written as they go.
    private func makeBatch(scheduledFor: Date?) -> MailBatch {
        let used = Set(letters.compactMap { $0.override == nil ? $0.templateID : nil })
        var snapshots: [MailTemplate.ID: MailBatch.TemplateSnapshot] = [:]
        for template in templates where used.contains(template.id) {
            snapshots[template.id] = .init(name: template.name, subject: template.subject, content: template.content)
        }
        let mails = letters.map { letter in
            QueuedMail(id: letter.id, recipient: letter.email, displayName: letter.name,
                       company: letter.company, context: letter.context,
                       templateID: letter.override == nil ? letter.templateID : nil,
                       override: letter.override)
        }
        let name = letters.count == 1 ? letters[0].name : title
        return MailBatch(id: UUID(), title: name, createdAt: .now, scheduledFor: scheduledFor,
                         fromName: profileStore.profile.name, templates: snapshots, mails: mails)
    }
}

// MARK: - Deck

/// How much of the next letter peeks in from the edge, so a batch reads as a
/// stack to swipe rather than one mail.
private let deckPeek: CGFloat = 18

/// Which letter the deck is showing. An observable object rather than `@State`
/// on the compose screen: it changes on every swipe, and only the few views
/// that show it — the counter, the dots, the To-line chips — should redraw,
/// not the whole screen with every letter in it.
@Observable
@MainActor
private final class DeckFocus {
    var id: MailPreview.ID?
}

/// The letters as a deck to swipe through. Lazy: a card exists only while it's
/// near the one on show, so a batch of 150 costs what a batch of three does.
private struct DeckScroller<Card: View>: View {
    let letters: [MailPreview]
    @Bindable var focus: DeckFocus
    @ViewBuilder let card: (MailPreview) -> Card

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(letters) { letter in
                    card(letter)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            width - Theme.Space.gutter * 2 - (letters.count > 1 ? deckPeek : 0)
                        }
                        .id(letter.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Theme.Space.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focus.id)
        .scrollDisabled(letters.count == 1)
    }
}

/// "3 of 150" over the deck. Also plays the selection tick as each letter lands.
private struct DeckCounter: View {
    let letters: [MailPreview]
    let focus: DeckFocus

    var body: some View {
        let index = letters.firstIndex { $0.id == focus.id } ?? 0
        Text("\(index + 1) of \(letters.count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.inkMuted)
            .contentTransition(.numericText())
            .animation(Theme.Motion.snappy, value: index)
            .sensoryFeedback(.selection, trigger: focus.id)
    }
}

/// A dot per letter under a small deck; the one on show is drawn long.
private struct PageDots: View {
    let batch: LetterBatch
    let focus: DeckFocus

    var body: some View {
        let letters = batch.letters
        let focusedIndex = letters.firstIndex { $0.id == focus.id } ?? 0
        HStack(spacing: 5) {
            ForEach(Array(letters.enumerated()), id: \.element.id) { index, letter in
                Capsule()
                    .fill(index == focusedIndex ? Color.clay
                          : (batch.missing(in: letter).isEmpty ? Color.inkFaint.opacity(0.5) : Color.kraft.opacity(0.7)))
                    .frame(width: index == focusedIndex ? 16 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.snappy, value: focusedIndex)
        .accessibilityHidden(true)
    }
}

/// The To line's row of people, one chip each. Lazy like the deck; the chip
/// for the letter on show stays in view as the deck is swiped.
private struct RecipientStrip: View {
    let batch: LetterBatch
    let focus: DeckFocus

    var body: some View {
        let letters = batch.letters
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(letters) { letter in
                        RecipientChip(name: letter.name,
                                      mark: letter.isEdited ? .edited : (batch.missing(in: letter).isEmpty ? nil : .blank),
                                      isFocused: letter.id == (focus.id ?? letters.first?.id)) {
                            withAnimation(Theme.Motion.snappy) { focus.id = letter.id }
                        }
                        .equatable()
                        .id(letter.id)
                    }
                }
            }
            .onChange(of: focus.id) { _, id in
                guard let id else { return }
                withAnimation(Theme.Motion.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// One person on the To line. Tapping it brings their letter to the front;
/// a dot says their letter needs a look (a blank) or has been hand-edited.
///
/// Takes only what it draws, and compares on that, so a template switch
/// leaves the chips alone.
private struct RecipientChip: View, Equatable {
    enum Mark { case blank, edited }

    let name: String
    let mark: Mark?
    let isFocused: Bool
    let onTap: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.mark == rhs.mark && lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        // No haptic of its own: the deck's selection tick plays as it lands.
        Button(action: onTap) {
            HStack(spacing: 6) {
                MonogramAvatar(text: name, size: 22)
                Text(name.split(separator: " ").first.map(String.init) ?? name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFocused ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
                switch mark {
                case .blank: Circle().fill(Color.kraft).frame(width: 6, height: 6)
                case .edited: Circle().fill(Color.slate).frame(width: 6, height: 6)
                case nil: EmptyView()
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(isFocused ? Color.clay.opacity(0.16) : Color.paperSunken, in: Capsule())
            .overlay(Capsule().strokeBorder(isFocused ? Color.clay.opacity(0.7) : .clear, lineWidth: 1))
            .animation(Theme.Motion.pop, value: isFocused)
        }
        .buttonStyle(BouncyPress(scale: 0.9))
        .accessibilityLabel(name)
        .accessibilityHint("Shows the mail to \(name)")
    }
}

// MARK: - Letter

/// One mail, drawn as a sheet of letter paper: who it's to, the subject set
/// large, then the body exactly as it will arrive.
private struct LetterCard<MenuItems: View>: View {
    let letter: MailPreview
    /// The letter as written, just now, for drawing.
    let face: LetterFace
    /// The deck's shared height, so a short letter matches its neighbours.
    var minHeight: CGFloat = 0
    let onEdit: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider().overlay(Color.hairline)

            if letter.templateID != nil || letter.isEdited {
                VStack(alignment: .leading, spacing: 12) {
                    Text(face.subject.isEmpty ? "No subject" : face.subject)
                        .font(.display(18))
                        .foregroundStyle(face.subject.isEmpty ? Color.inkFaint : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(face.body)
                        .font(.callout)
                        .foregroundStyle(Color.ink.opacity(0.88))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(14)
            } else {
                Text("Choose a template above and this mail writes itself.")
                    .font(.callout)
                    .foregroundStyle(.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .multilineTextAlignment(.center)
                    .padding(14)
            }

            if let other = face.writtenFor {
                warningStrip(symbol: "building.2.fill",
                             text: "Written for \(other) — this goes to \(letter.company)",
                             action: "Edit", onTap: onEdit)
            }
            if !face.missing.isEmpty {
                warningStrip(symbol: "circle.dashed",
                             text: "Blank here: " + face.missing.map(\.blankLabel).joined(separator: ", "),
                             action: "Fill in", onTap: onEdit)
            }
        }
        .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .top)
        .panelAccented(face.missing.isEmpty && face.writtenFor == nil ? nil : Color.kraft,
                       radius: Theme.Radius.hero)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MonogramAvatar(text: letter.name, size: Theme.Avatar.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(letter.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    if letter.isEdited {
                        StatusChip(text: "Edited", systemImage: "pencil", color: .slate)
                    }
                }
                Text("\(letter.email) · \(letter.company)")
                    .font(.caption)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                Haptics.tap()
                onEdit()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.clay)
                    .frame(width: 34, height: 34)
                    .background(Color.clay.opacity(0.12), in: Circle())
            }
            .buttonStyle(BouncyPress(scale: 0.84))
            .accessibilityLabel("Edit mail to \(letter.name)")

            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.inkMuted)
                    .frame(width: 34, height: 34)
                    .background(Color.paperSunken, in: Circle())
            }
            .accessibilityLabel("More for \(letter.name)")
        }
    }

    /// Something to look at before this letter goes: a template meant for
    /// another company, or the placeholders it left empty, named — "their
    /// role", "your college" — so it's clear what to fix before it reads oddly.
    private func warningStrip(symbol: String, text: String, action: String,
                              onTap: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: onTap)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.clay)
        }
        .foregroundStyle(.kraft)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.kraft.opacity(0.10))
    }
}

/// One person's mail on the compose screen — who it's to, and what it's
/// written from: a template, or the words it was rewritten with by hand. The
/// text itself isn't kept; it's written when the letter is drawn (`LetterBatch.face`).
struct MailPreview: Identifiable {
    let id: Contact.ID
    let contact: Contact
    let company: String
    /// What the placeholders fill in with for this person, worked out once —
    /// the greeting alone takes some reading of their name — and reused by
    /// every template the letter is written from.
    let context: MailContext
    /// Placeholders with nothing to fill them for this person. Never the name:
    /// an empty one means no name could be trusted, and "Hi," is the right mail.
    let blanks: Set<MailPlaceholder>
    let name: String
    let email: String
    var templateID: MailTemplate.ID?
    /// Rewritten by hand: sent as is, whatever template the rest are on.
    var override: QueuedMail.Override?

    var isEdited: Bool { override != nil }

    init(contact: Contact, company: String, context: MailContext, templateID: MailTemplate.ID?) {
        self.id = contact.id
        self.contact = contact
        self.company = company
        self.context = context
        self.blanks = Set(MailPlaceholder.allCases.filter {
            $0 != .receiverName && (context.values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        })
        self.name = contact.displayName
        self.email = contact.email
        self.templateID = templateID
    }
}

/// One letter as written for drawing: its text, and what to flag on it.
private struct LetterFace {
    var subject = ""
    var body = ""
    /// Placeholders the template used that had nothing to fill them here.
    var missing: [MailPlaceholder] = []
    /// The other company the letter's template was written for, when it isn't
    /// this recipient's.
    var writtenFor: String?
}

/// A template parsed once for the whole compose screen (see `MailText`).
private struct ParsedTemplate {
    let subject: MailText
    let body: MailText
    /// Every placeholder it uses, subject and body.
    let placeholders: Set<MailPlaceholder>
    /// The company it was written for, if it's one company's template.
    let writtenFor: String?

    init(_ template: MailTemplate, writtenFor: String?) {
        subject = MailText(template.subject)
        body = MailText(template.content)
        placeholders = subject.placeholders.union(body.placeholders)
        self.writtenFor = writtenFor
    }
}

/// The letters, the templates they're written from, and the counts the screen
/// shows about them — how many use each template, have a blank, lack a
/// subject — worked out once per change rather than by every view that shows
/// one, each time it draws.
private struct LetterBatch {
    struct Tally {
        var perTemplate: [MailTemplate.ID: Int] = [:]
        var companies: Set<String> = []
        var unwritten = 0
        var blanks = 0
        var mismatched = 0
        var anyEdited = false
        /// The letter that draws tallest, roughly — the deck sizes to it.
        var longestID: MailPreview.ID?
    }

    /// Set whole — not letter by letter — so the tally is redone once.
    var letters: [MailPreview] = [] {
        didSet { recount() }
    }
    /// Every template, parsed, by id.
    var parsed: [MailTemplate.ID: ParsedTemplate] = [:] {
        didSet { recount() }
    }
    private(set) var tally = Tally()

    /// The letter written out, now — only ever for the few being drawn.
    func face(of letter: MailPreview) -> LetterFace {
        if let override = letter.override {
            return LetterFace(subject: override.subject, body: override.body)
        }
        guard let template = template(of: letter) else { return LetterFace() }
        return LetterFace(subject: template.subject.filled(with: letter.context),
                          body: template.body.filled(with: letter.context),
                          missing: missing(in: letter),
                          writtenFor: writtenFor(letter, template))
    }

    /// The placeholders left blank in `letter` — without writing it.
    func missing(in letter: MailPreview) -> [MailPlaceholder] {
        guard letter.override == nil, let template = template(of: letter) else { return [] }
        return MailPlaceholder.allCases.filter { template.placeholders.contains($0) && letter.blanks.contains($0) }
    }

    private func template(of letter: MailPreview) -> ParsedTemplate? {
        letter.templateID.flatMap { parsed[$0] }
    }

    private func writtenFor(_ letter: MailPreview, _ template: ParsedTemplate) -> String? {
        template.writtenFor.flatMap { $0 == letter.company ? nil : $0 }
    }

    private mutating func recount() {
        var tally = Tally()
        var longest = -1
        for letter in letters {
            tally.companies.insert(letter.company)
            let length: Int
            if let override = letter.override {
                tally.anyEdited = true
                if override.subject.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) {
                    tally.unwritten += 1
                }
                length = override.subject.utf8.count + override.body.utf8.count
            } else if let template = template(of: letter) {
                if let id = letter.templateID { tally.perTemplate[id, default: 0] += 1 }
                // Only the subject is written, to see whether it's empty; it's short.
                if template.subject.filled(with: letter.context)
                    .unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) {
                    tally.unwritten += 1
                }
                let blank = !template.placeholders.isDisjoint(with: letter.blanks)
                if blank { tally.blanks += 1 }
                let mismatched = writtenFor(letter, template) != nil
                if mismatched { tally.mismatched += 1 }
                // Roughly how tall it draws: its length, and a line for each warning.
                length = template.subject.length(with: letter.context) + template.body.length(with: letter.context)
                    + (blank ? 120 : 0) + (mismatched ? 120 : 0)
            } else {
                tally.unwritten += 1
                length = 0
            }
            if length > longest {
                longest = length
                tally.longestID = letter.id
            }
        }
        self.tally = tally
    }
}

/// A drawer for tailoring a single mail's subject and body before sending.
/// Edits are local until "Save", which hands them back to the compose screen.
struct MailEditorView: View {
    let name: String
    let email: String
    let missing: [MailPlaceholder]
    let onSave: (_ subject: String, _ body: String) -> Void

    private let original: (subject: String, body: String)
    @State private var subject: String
    @State private var messageBody: String
    @Environment(\.dismiss) private var dismiss

    fileprivate init(letter: MailPreview, face: LetterFace, onSave: @escaping (String, String) -> Void) {
        self.name = letter.name
        self.email = letter.email
        self.missing = face.missing
        self.onSave = onSave
        original = (face.subject, face.body)
        _subject = State(initialValue: face.subject)
        _messageBody = State(initialValue: face.body)
    }

    private var hasChanges: Bool { subject != original.subject || messageBody != original.body }

    var body: some View {
        NavigationStack {
            PaperForm {
                Section("To") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                    }
                }
                if !missing.isEmpty {
                    Section {
                        Label("The template left " + missing.map(\.blankLabel).joined(separator: ", ")
                              + " blank in this mail. Fill it in below, or reword around it.",
                              systemImage: "circle.dashed")
                            .font(.footnote)
                            .foregroundStyle(.kraft)
                    }
                }
                Section("Subject") {
                    TextField("Subject", text: $subject, axis: .vertical)
                }
                Section("Message") {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 260)
                        .font(.callout)
                }
            }
            .navigationTitle("Edit Mail")
            .navigationBarTitleDisplayMode(.inline)
            .discardableEdits(hasChanges)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.success()
                        onSave(subject.sanitizedLineSeparators, messageBody.sanitizedLineSeparators)
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
