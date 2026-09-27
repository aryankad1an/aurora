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
/// - one **Send** button, which says what's in the way when something is.
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

    private let recipients: [(contact: Contact, company: String)]
    /// Mailable people beyond `batchLimit`, left for another batch.
    private let leftOver: Int

    /// The most one batch writes. Every letter in the deck is drawn at once,
    /// and past a few dozen the screen stalls; more to the point, Gmail caps
    /// what a personal account may send in a day, and hundreds of near-identical
    /// mails in one go is the pattern its spam filters look for — the damage
    /// lands on the sender's own reputation.
    static let batchLimit = 50

    /// The mails as they stand — rendered from a template, then tailored.
    @State private var letters: [MailPreview] = []
    /// The template the whole batch was last written from. Individual letters can
    /// be moved onto another one from their own menu.
    @State private var templateID: MailTemplate.ID?
    /// The letter the deck is showing.
    @State private var focusedID: MailPreview.ID?
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
        let mailable = recipients.filter(\.contact.isMailable)
        self.recipients = Array(mailable.prefix(Self.batchLimit))
        self.leftOver = max(0, mailable.count - Self.batchLimit)
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

    private var companyCount: Int { Set(letters.map(\.company)).count }

    private var focusedIndex: Int {
        letters.firstIndex { $0.id == focusedID } ?? 0
    }

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
            .discardableEdits(letters.contains(where: \.isEdited),
                              message: "The mails you edited by hand won't be kept.")
            .safeAreaInset(edge: .bottom) { sendBar }
            .sheet(item: $editing) { letter in
                MailEditorView(preview: letter) { subject, body in
                    apply(id: letter.id, subject: subject, body: body)
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
            // on another device); the first one to land writes the letters.
            .onChange(of: templates.map(\.id)) { start() }
            .sensoryFeedback(.selection, trigger: focusedID)
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
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(letters) { letter in
                                        recipientChip(letter).id(letter.id)
                                    }
                                }
                            }
                            // The chip for the letter on show stays in view as
                            // the deck is swiped.
                            .onChange(of: focusedID) { _, id in
                                guard let id else { return }
                                withAnimation(Theme.Motion.snappy) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                        Text("\(letters.count) people" + (companyCount > 1 ? " · \(companyCount) companies" : ""))
                            .font(.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                        if leftOver > 0 {
                            Label("The first \(Self.batchLimit), in order — \(leftOver) more for another batch",
                                  systemImage: "tray.full")
                                .font(.caption)
                                .foregroundStyle(.kraft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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

    /// One person on the To line. Tapping it brings their letter to the front;
    /// a dot says their letter needs a look (a blank) or has been hand-edited.
    private func recipientChip(_ letter: MailPreview) -> some View {
        let isFocused = letter.id == (focusedID ?? letters.first?.id)
        // No haptic of its own: the deck's selection tick plays as it lands.
        return Button {
            withAnimation(Theme.Motion.snappy) { focusedID = letter.id }
        } label: {
            HStack(spacing: 6) {
                MonogramAvatar(text: letter.name, size: 22)
                Text(letter.name.split(separator: " ").first.map(String.init) ?? letter.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFocused ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
                if !letter.missing.isEmpty {
                    Circle().fill(Color.kraft).frame(width: 6, height: 6)
                } else if letter.isEdited {
                    Circle().fill(Color.slate).frame(width: 6, height: 6)
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
        .accessibilityLabel(letter.name)
        .accessibilityHint("Shows the mail to \(letter.name)")
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
        let count = letters.count { $0.templateID == template.id }
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
                        Text("\(focusedIndex + 1) of \(letters.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.inkMuted)
                            .contentTransition(.numericText())
                            .animation(Theme.Motion.snappy, value: focusedIndex)
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: every letter is measured, so they're all drawn
                    // at the height of the longest and the deck doesn't change
                    // height under the finger as it's swiped.
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(letters) { letter in
                            LetterCard(letter: letter,
                                       hasTemplate: letter.templateID != nil,
                                       onEdit: { editing = letter }) {
                                letterMenu(letter)
                            }
                            // The next letter peeks in from the edge, so a batch
                            // reads as a stack to swipe rather than one mail.
                            .containerRelativeFrame(.horizontal) { width, _ in
                                width - Theme.Space.gutter * 2 - (letters.count > 1 ? 18 : 0)
                            }
                            .id(letter.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Theme.Space.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $focusedID)
                .scrollDisabled(letters.count == 1)

                if letters.count > 1 && letters.count <= 16 {
                    pageDots
                }
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(Array(letters.enumerated()), id: \.element.id) { index, letter in
                Capsule()
                    .fill(index == focusedIndex ? Color.clay
                          : (letter.missing.isEmpty ? Color.inkFaint.opacity(0.5) : Color.kraft.opacity(0.7)))
                    .frame(width: index == focusedIndex ? 16 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.snappy, value: focusedIndex)
        .accessibilityHidden(true)
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
        if letters.isEmpty { return "Nobody here can be mailed." }
        if !gmail.isConnected { return "Connect Gmail in Profile to send." }
        if templates.isEmpty && letters.allSatisfy({ $0.templateID == nil && !$0.isEdited }) {
            return "Write a template first."
        }
        let unwritten = letters.count { $0.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if unwritten > 0 {
            return unwritten == 1 && letters.count == 1
                ? "This mail has no subject."
                : "\(unwritten) of \(letters.count) mails have no subject."
        }
        return nil
    }

    /// Blanks don't block — a missing role often reads fine — but they're
    /// counted here, where they're the last thing seen before sending.
    private var blankCount: Int { letters.count { !$0.missing.isEmpty } }

    /// Mails written from a template meant for another company. Not a blocker
    /// — the text may have been fixed by hand — but it's the first warning.
    private var mismatchCount: Int { letters.count { $0.writtenFor != nil } }

    /// Whether picking `template` would write mails naming the wrong company.
    private func isMismatched(_ template: MailTemplate) -> Bool {
        guard let company = templateCompany[template.id] else { return false }
        return letters.contains { $0.company != company }
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

    /// Write every letter from the first template, once there is one. Runs again
    /// if the templates arrive late, but never over a hand edit.
    private func start() {
        let tracked = jobStore.jobs.map(\.company)
        templateCompany = templates.reduce(into: [:]) { result, template in
            result[template.id] = template.writtenFor(amongst: tracked)
        }
        guard letters.isEmpty || (templateID == nil && !letters.contains(where: \.isEdited)) else { return }
        let template = templateID.flatMap { id in templates.first { $0.id == id } } ?? defaultTemplate
        templateID = template?.id
        letters = recipients.map { render($0.contact, company: $0.company, template: template) }
        if focusedID == nil { focusedID = letters.first?.id }
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
        if letters.contains(where: \.isEdited) && template.id != templateID {
            pendingTemplate = template
        } else {
            write(template, to: Set(letters.map(\.id)))
        }
    }

    /// Re-write the given letters from `template`, replacing any hand edits.
    private func write(_ template: MailTemplate, to ids: Set<MailPreview.ID>) {
        withAnimation(Theme.Motion.snappy) {
            for index in letters.indices where ids.contains(letters[index].id) {
                letters[index] = render(letters[index].contact, company: letters[index].company, template: template)
            }
            if ids.count == letters.count { templateID = template.id }
        }
    }

    private func render(_ contact: Contact, company: String, template: MailTemplate?) -> MailPreview {
        guard let template else {
            return MailPreview(id: contact.id, contact: contact, company: company,
                               name: contact.displayName, email: contact.email,
                               subject: "", body: "", templateID: nil)
        }
        let context = MailContext.make(contact: contact, company: company, profile: profileStore.profile)
        let used = template.subject + template.content
        let missing = MailPlaceholder.allCases.filter { placeholder in
            used.contains(placeholder.token)
                && (context.values[placeholder] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        return MailPreview(id: contact.id, contact: contact, company: company,
                           name: contact.displayName, email: contact.email,
                           subject: context.fill(template.subject),
                           body: context.fill(template.content),
                           templateID: template.id,
                           missing: missing,
                           writtenFor: templateCompany[template.id].flatMap { $0 == company ? nil : $0 })
    }

    /// Write a hand edit back into its letter. The letter has been read and
    /// written by a person now, so its blanks stop being flagged.
    private func apply(id: MailPreview.ID, subject: String, body: String) {
        guard let index = letters.firstIndex(where: { $0.id == id }) else { return }
        letters[index].subject = subject
        letters[index].body = body
        letters[index].isEdited = true
        letters[index].missing = []
        // Read and rewritten by a person: whatever it names is now on purpose.
        letters[index].writtenFor = nil
    }

    private func leaveOut(_ letter: MailPreview) {
        Haptics.thud()
        guard let index = letters.firstIndex(where: { $0.id == letter.id }) else { return }
        let next = letters.indices.contains(index + 1) ? letters[index + 1].id : letters[max(0, index - 1)].id
        withAnimation(Theme.Motion.snappy) {
            letters.remove(at: index)
            focusedID = letters.contains { $0.id == next } ? next : letters.first?.id
        }
    }

    /// Hand the letters to the background queue and get out of the way. Exactly
    /// what's on screen goes out, hand edits included.
    private func send() {
        let mails = letters.map {
            MailQueue.Mail(id: $0.id, recipient: $0.email, displayName: $0.name,
                           subject: $0.subject, body: $0.body)
        }
        guard !mails.isEmpty else { return }
        // A rising run, one beat per mail. Sending eight shouldn't feel identical
        // to sending one, and this is the last moment the user is still holding
        // the phone waiting to find out that it worked.
        Haptics.cascade(mails.count)
        if let templateID { lastTemplateID = templateID.uuidString }
        mailQueue.enqueue(mails, fromName: profileStore.profile.name)
        if let onSent { onSent() } else { dismiss() }
    }
}

// MARK: - Letter

/// One mail, drawn as a sheet of letter paper: who it's to, the subject set
/// large, then the body exactly as it will arrive.
private struct LetterCard<MenuItems: View>: View {
    let letter: MailPreview
    let hasTemplate: Bool
    let onEdit: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider().overlay(Color.hairline)

            if hasTemplate || letter.isEdited {
                VStack(alignment: .leading, spacing: 12) {
                    Text(letter.subject.isEmpty ? "No subject" : letter.subject)
                        .font(.display(18))
                        .foregroundStyle(letter.subject.isEmpty ? Color.inkFaint : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(letter.body)
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

            if let other = letter.writtenFor {
                warningStrip(symbol: "building.2.fill",
                             text: "Written for \(other) — this goes to \(letter.company)",
                             action: "Edit", onTap: onEdit)
            }
            if !letter.missing.isEmpty {
                warningStrip(symbol: "circle.dashed",
                             text: "Blank here: " + letter.missing.map(\.blankLabel).joined(separator: ", "),
                             action: "Fill in", onTap: onEdit)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelAccented(letter.missing.isEmpty && letter.writtenFor == nil ? nil : Color.kraft,
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

/// One fully rendered mail, ready to send. Subject/body are mutable so each can
/// be tailored before sending. Carries the source `contact`, `company`, and the
/// `templateID` it was rendered from so it can be re-rendered from another.
struct MailPreview: Identifiable {
    let id: Contact.ID
    let contact: Contact
    let company: String
    let name: String
    let email: String
    var subject: String
    var body: String
    var templateID: MailTemplate.ID?
    /// Placeholders the template used that had nothing to fill them with here.
    var missing: [MailPlaceholder] = []
    /// The other company this mail's template was written for, when it isn't
    /// this recipient's.
    var writtenFor: String?
    /// Changed by hand since it was rendered.
    var isEdited = false
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

    init(preview: MailPreview, onSave: @escaping (String, String) -> Void) {
        self.name = preview.name
        self.email = preview.email
        self.missing = preview.missing
        self.onSave = onSave
        original = (preview.subject, preview.body)
        _subject = State(initialValue: preview.subject)
        _messageBody = State(initialValue: preview.body)
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
