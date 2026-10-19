import SwiftUI

/// What the assistant is told about a company when asked to write a line for it.
struct DraftSubject {
    let company: String
    let sector: String?
}

/// The sparkles button: Apple Intelligence's cloud model (see `WritingAssistant`)
/// on the text it's bound to — quick fixes, the user's own instruction, and, for
/// a company line, a first draft — with every answer shown as a comparison and
/// applied only once approved. The system's own Writing Tools stay one tap away
/// in the same sheet, through `writingTools`. After a change is accepted, Undo
/// sits beside the button until the text is edited again.
struct WritingAssistButton: View {
    @Binding var text: String
    /// What the text is and where it goes, which the model is told.
    let place: WritingPlace
    /// The paired editor, for opening the system's Writing Tools on it instead.
    var writingTools: WritingToolsTarget?
    /// Called when an approved change has been written into `text`.
    var onApplied: () -> Void = {}

    @State private var assistant = WritingAssistant()
    /// The open sheet's progress, kept here because the sheet's own state is
    /// thrown away when the app comes back from Shortcuts.
    @State private var session = WritingHelpSession()
    /// Set when the sheet was closed to open Writing Tools, which waits for it to go.
    @State private var openWritingToolsAfter = false
    @State private var showing = false
    /// The text an accepted change left behind, to tell whether it has been
    /// edited since (after which Undo would throw those edits away).
    @State private var applied: String?

    var body: some View {
        HStack(spacing: 12) {
            if assistant.previous != nil {
                Button {
                    guard let old = assistant.undo() else { return }
                    Haptics.tap()
                    withAnimation(Theme.Motion.snappy) { text = old }
                    onApplied()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.clay.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.clay)
                }
                .buttonStyle(BouncyPress(scale: 0.92))
                .accessibilityLabel("Undo the writing help change")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Button {
                Haptics.tap()
                session = WritingHelpSession()
                showing = true
            } label: {
                Image(systemName: "sparkles")
                    .symbolEffect(.bounce, value: assistant.previous)
            }
            .accessibilityLabel("Writing help")
            .accessibilityHint("Apple Intelligence: proofread, rewrite, or tell it what to change")
        }
        .animation(Theme.Motion.snappy, value: assistant.previous != nil)
        .sheet(isPresented: $showing, onDismiss: {
            guard openWritingToolsAfter else { return }
            openWritingToolsAfter = false
            Task { await writingTools?.open() }
        }) {
            WritingAssistSheet(text: $text, place: place, assistant: assistant, session: session, onApplied: {
                applied = text
                onApplied()
            }, onUseWritingTools: writingTools == nil ? nil : {
                openWritingToolsAfter = true
                showing = false
            })
        }
        .onChange(of: text) { _, now in
            if assistant.previous != nil, now != applied { assistant.forgetUndo() }
        }
    }
}

/// Where one opening of the writing-help sheet has got to. It lives with the
/// button rather than in the sheet: when Aurora comes back from Shortcuts the
/// system rebuilds the sheet's content with fresh state, which would drop the
/// request that's out and close the shortcut setup over it.
@MainActor @Observable
final class WritingHelpSession {
    enum Stage: Equatable { case compose, working, review }
    var stage = Stage.compose
    /// The text as the sheet opened, which every comparison is made against.
    var original = ""
    /// The answer under review.
    var candidate = ""
    /// What the answer was made from, and what was asked, for Try Again.
    var lastSource = ""
    var lastRequest: WritingRequest?
    /// How many times the same request has been asked again, so each Try Again
    /// varies more.
    var attempts = 0
    var prompt = ""
    var refinement = ""
    var tab = ChangeComparison.Tab.changes
    var job: Task<Void, Never>?
    var burst: Date?
    var loaded = false
    var showingShortcutSetup = false
    let shortcutTest = ShortcutTest()
}

/// The writing-help sheet: ask → watch it work → review what changed → approve.
struct WritingAssistSheet: View {
    @Binding var text: String
    let place: WritingPlace
    let assistant: WritingAssistant
    @Bindable var session: WritingHelpSession
    let onApplied: () -> Void
    /// Closes the sheet and opens the system's Writing Tools on the text instead.
    var onUseWritingTools: (() -> Void)?

    private typealias Stage = WritingHelpSession.Stage
    private typealias Tab = ChangeComparison.Tab

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ProfileStore.self) private var profileStore

    // The session's fields under their own names, so the views below read plainly.
    private var stage: Stage { get { session.stage } nonmutating set { session.stage = newValue } }
    private var original: String { get { session.original } nonmutating set { session.original = newValue } }
    private var candidate: String { get { session.candidate } nonmutating set { session.candidate = newValue } }
    private var lastSource: String { get { session.lastSource } nonmutating set { session.lastSource = newValue } }
    private var lastRequest: WritingRequest? { get { session.lastRequest } nonmutating set { session.lastRequest = newValue } }
    private var attempts: Int { get { session.attempts } nonmutating set { session.attempts = newValue } }
    private var prompt: String { get { session.prompt } nonmutating set { session.prompt = newValue } }
    private var refinement: String { get { session.refinement } nonmutating set { session.refinement = newValue } }
    private var tab: Tab { get { session.tab } nonmutating set { session.tab = newValue } }
    private var job: Task<Void, Never>? { get { session.job } nonmutating set { session.job = newValue } }
    private var burst: Date? { get { session.burst } nonmutating set { session.burst = newValue } }

    /// Read here so the sheet redraws when the shortcut is switched on or off.
    @AppStorage(ShortcutsWriter.enabledKey) private var viaShortcuts = false
    /// One column for the icons beside what the model is told.
    @ScaledMetric(relativeTo: .footnote) private var factIconWidth = 20.0
    @FocusState private var promptFocused: Bool
    @FocusState private var refineFocused: Bool

    private var subject: DraftSubject? { place.draftSubject }
    private var isTemplate: Bool { place.isTemplate }
    private var known: [String] { isTemplate ? MailPlaceholder.allCases.map(\.token) : [] }

    /// The sender's real details, for a mail that is already filled in: "mention
    /// my college" has nothing to stand for the college there but the college.
    private var senderFacts: String? {
        let profile = profileStore.profile
        var facts: [String] = []
        if !profile.name.isEmpty { facts.append("name: \(profile.name)") }
        if profile.isStudying, !profile.college.isEmpty { facts.append("studies at \(profile.college)") }
        if profile.isWorking, !profile.company.isEmpty {
            facts.append("works at \(profile.company)" + (profile.position.isEmpty ? "" : " as \(profile.position)"))
        }
        if !profile.resumeLink.isEmpty { facts.append("resume link: \(profile.resumeLink)") }
        return facts.isEmpty ? nil : facts.joined(separator: "; ")
    }
    private var hasText: Bool { !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var unavailable: String? { WritingAssistant.unavailableReason }

    var body: some View {
        NavigationStack {
            ZStack {
                switch stage {
                case .compose: compose.transition(Self.stageTransition)
                case .working: working.transition(Self.stageTransition)
                case .review: review.transition(Self.stageTransition)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: stage)
            .paperScreen()
            .overlay { acceptedSeal }
            .navigationTitle("Writing Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .onAppear {
                guard !session.loaded else { return }
                session.loaded = true
                original = text
            }
            .messageAlert("Apple Intelligence", message: assistant.failure) { assistant.failure = nil }
            .sheet(isPresented: $session.showingShortcutSetup) { ShortcutSetupView(test: session.shortcutTest) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Out of compose, a swipe would leave a change undecided: it's Accept
        // or Discard (or the close button, which discards).
        .interactiveDismissDisabled(stage != .compose)
    }

    /// One stage leaves quickly and the next arrives just behind it, so the two
    /// are never on screen as overlapping ghosts.
    private static let stageTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97))
            .animation(.easeOut(duration: 0.3).delay(0.12)),
        removal: .opacity.animation(.easeIn(duration: 0.12)))

    // MARK: - Ask

    private var compose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let unavailable {
                    unavailableCard(unavailable)
                    if hasText { writingToolsRow }
                    shortcutRow
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(hasText ? "Tell it what to do" : (subject == nil ? "Tell it what to do" : "What should it say?"))
                        promptField(text: $session.prompt, focus: $promptFocused,
                                    placeholder: hasText ? "e.g. Mention I'm a final-year student"
                                                         : (subject == nil ? "Nothing to change yet"
                                                                           : "e.g. I built a project using their API")) {
                            // With nothing written yet, what's typed is what the line should
                            // say, not an instruction about text that doesn't exist.
                            run(hasText ? .custom(prompt) : .draft(notes: prompt), from: original)
                        }
                        .disabled(!hasText && subject == nil)
                        if hasText || subject != nil { suggestions }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(hasText ? "Or pick a quick fix" : "Start")
                        quickActions
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("What it's working with")
                        context
                    }

                    if assistant.previous != nil { undoRow }
                    if WritingAssistant.isApproachingLimit {
                        Label("You're close to your share of Apple Intelligence cloud requests for now.",
                              systemImage: "gauge.with.dots.needle.67percent")
                            .font(.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                    if hasText { writingToolsRow }
                    shortcutRow
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AIStyle.linear)
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: !reduceMotion && unavailable == nil)
                .frame(width: 44, height: 44)
                .background(Color.clay.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence")
                    .font(.headline)
                    .padding(.top, 2)
                    .foregroundStyle(Color.ink)
                Text(WritingAssistant.usesCloud
                     ? "Apple's larger cloud model, the one Siri uses. Private Cloud Compute keeps your text private to the request."
                     : viaShortcuts
                     ? "Through your \(ShortcutsWriter.shortcutName) shortcut, with the model you chose in it. If it doesn't answer, the model on your iPhone writes instead."
                     : "The model on your iPhone. It's smaller than Siri's, so check what it changes. Writing Tools can use the larger one.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color.inkMuted)
    }

    /// The text the request works on and what the model is told about it, so
    /// it's plain what the answer is written for.
    private var context: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if hasText {
                    Text(original)
                        .foregroundStyle(Color.ink)
                        .lineLimit(3)
                } else {
                    Text("Nothing written yet.")
                        .foregroundStyle(Color.inkFaint)
                }
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(place.facts(hasProfile: senderFacts != nil), id: \.text) { fact in
                    Label {
                        Text(fact.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: fact.systemImage)
                            .foregroundStyle(Color.clay)
                            .frame(width: factIconWidth)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel(radius: Theme.Radius.inner)
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        AdaptiveFlow(spacing: 8) {
            if subject != nil {
                actionChip(hasText ? "Write a new one" : "Write one for me",
                           systemImage: "wand.and.stars", prominent: !hasText) {
                    run(.draft(notes: nil), from: original)
                }
            }
            ForEach(WritingAction.allCases) { action in
                actionChip(action.title, systemImage: action.systemImage, prominent: false) {
                    run(.preset(action), from: original)
                }
                .disabled(!hasText)
                .opacity(hasText ? 1 : 0.45)
            }
        }
    }

    private func actionChip(_ title: String, systemImage: String, prominent: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
                .frame(minHeight: 36)
                .background(prominent ? Color.clay : Color.clay.opacity(0.14), in: Capsule())
                .foregroundStyle(prominent ? Color.white : Color.clay)
        }
        .buttonStyle(BouncyPress(scale: 0.92))
    }

    /// Prompts written out in full: a tap puts one in the box to send as it is or
    /// reword first.
    private var suggestions: some View {
        let ideas = PromptIdeas.ideas(for: place.ideaKind, text: original, profile: profileStore.profile)
        return VStack(alignment: .leading, spacing: 6) {
            Label("Tap an idea to fill it in, then edit or send", systemImage: "text.insert")
                .font(.caption2)
                .foregroundStyle(Color.inkFaint)
            AdaptiveFlow(spacing: 6) {
                ForEach(ideas, id: \.self) { idea in
                    Button {
                        Haptics.select()
                        withAnimation(Theme.Motion.snappy) { prompt = idea }
                        promptFocused = true
                    } label: {
                        Text(idea)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(prompt == idea ? Color.clay.opacity(0.14) : Color.paperSunken, in: Capsule())
                            .foregroundStyle(prompt == idea ? Color.clay : Color.inkMuted)
                    }
                    .buttonStyle(BouncyPress(scale: 0.94))
                    .accessibilityHint("Puts this in the box to edit or send")
                }
            }
        }
    }

    /// The system's own Writing Tools on the text, for its inline proofreading
    /// marks or when the cloud model can't be reached.
    @ViewBuilder
    private var writingToolsRow: some View {
        if let onUseWritingTools {
            Button {
                Haptics.tap()
                onUseWritingTools()
            } label: {
                Label("Use Writing Tools instead", systemImage: "pencil.and.scribble")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.clay)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .secondaryButton()
        }
    }

    /// Setting up, or switching, the Aurora Writer shortcut: the way to Siri's
    /// larger model without the cloud entitlement.
    @ViewBuilder
    private var shortcutRow: some View {
        if !WritingAssistant.usesCloud {
            Button {
                Haptics.tap()
                session.showingShortcutSetup = true
            } label: {
                Label(viaShortcuts ? "\(ShortcutsWriter.shortcutName) shortcut: on" : "Use Siri's larger model through Shortcuts",
                      systemImage: "square.2.layers.3d")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.clay)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .secondaryButton()
        }
    }

    private var undoRow: some View {
        Button {
            if let old = assistant.undo() {
                Haptics.tap()
                text = old
                original = old
                onApplied()
            }
        } label: {
            Label("Undo the last change", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.clay)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .secondaryButton()
        .transition(.liquid)
    }

    private func unavailableCard(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(Color.inkFaint)
            Text("Not available right now")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .panel()
    }

    /// A text box with a send button, ringed in colour while it has focus.
    private func promptField(text: Binding<String>, focus: FocusState<Bool>.Binding, placeholder: String,
                             onSend: @escaping () -> Void) -> some View {
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .foregroundStyle(Color.ink)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit { if !trimmed.isEmpty { onSend() } }
            Button {
                Haptics.tap()
                onSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(trimmed.isEmpty ? Color.inkFaint : Color.clay)
                    .symbolEffect(.bounce, value: trimmed.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .panel(radius: 22)
        .overlay {
            AIGlowBorder(cornerRadius: 22, lineWidth: 1.5, halo: 0.12)
                .opacity(focus.wrappedValue ? 1 : 0)
                .animation(Theme.Motion.snappy, value: focus.wrappedValue)
        }
    }

    // MARK: - Working

    private var working: some View {
        // Scrolls, held to the bottom, so a long answer streams in where it can
        // be read and Stop stays in reach.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 12) {
                        if let lastRequest {
                            Label(lastRequest.title, systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.clay)
                                .lineLimit(1)
                        }
                        Group {
                            if assistant.streamed.isEmpty {
                                Text(lastSource.isEmpty ? "Thinking of something to say…" : lastSource)
                                    .aiShimmer()
                            } else {
                                Text(assistant.streamed)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                    }
                    .padding(16)
                    .panel()
                    .overlay { AIGlowBorder() }

                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        Text(assistant.isInShortcuts ? "Writing in Shortcuts…" : assistant.streamed.isEmpty ? "Reading…" : "Writing…")
                            .contentTransition(.opacity)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.inkMuted)

                    Button("Stop") {
                        Haptics.tap()
                        job?.cancel()
                        stage = .compose
                    }
                    .secondaryButton()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.vertical, 16)
                .frame(minHeight: proxy.size.height)
            }
            .defaultScrollAnchor(.bottom)
        }
        .animation(Theme.Motion.snappy, value: assistant.streamed.isEmpty)
    }

    // MARK: - Review

    private var diff: TextDiff { TextDiff(from: original, to: candidate) }

    private var review: some View {
        let diff = diff
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        if let lastRequest {
                            Label(lastRequest.title, systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.clay)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        ChangeTally(diff: diff)
                    }

                    if let notice = assistant.notice {
                        Label(notice, systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }

                    ChangeComparison(before: original, after: candidate, tab: $session.tab)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Not quite? Say what to adjust")
                        promptField(text: $session.refinement, focus: $refineFocused,
                                    placeholder: "e.g. Keep it shorter") {
                            run(.custom(refinement), from: candidate)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            reviewBar(diff)
        }
    }

    private func reviewBar(_ diff: TextDiff) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            Label(place.destination, systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            buttons(diff, stacked: stacked, layout: layout)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func buttons(_ diff: TextDiff, stacked: Bool, layout: AnyLayout) -> some View {
        layout {
            if stacked { acceptButton(diff) }
            Button {
                Haptics.tap()
                withAnimation { stage = .compose }
            } label: {
                Text("Discard")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .secondaryButton()

            Button {
                if let lastRequest { run(lastRequest, from: lastSource) }
            } label: {
                Group {
                    if stacked {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 28)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 28, minHeight: 28)
                    }
                }
            }
            .secondaryButton()
            .accessibilityLabel("Try again")

            if !stacked { acceptButton(diff) }
        }
    }

    private func acceptButton(_ diff: TextDiff) -> some View {
        Button { accept() } label: {
            Label("Accept", systemImage: "checkmark")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .primaryButton()
        .disabled(!diff.hasChanges)
    }

    // MARK: - Accepted

    /// A tick and a burst of sparkles over the sheet as the change is written in.
    @ViewBuilder
    private var acceptedSeal: some View {
        if burst != nil {
            ZStack {
                Color.paper.opacity(0.9).ignoresSafeArea()
                AISparkleBurst()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(AIStyle.linear)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func run(_ request: WritingRequest, from source: String) {
        promptFocused = false
        refineFocused = false
        guard !(request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return }
        attempts = (request == lastRequest && source == lastSource) ? attempts + 1 : 0
        lastRequest = request
        lastSource = source
        let attempt = attempts
        withAnimation { stage = .working }
        job?.cancel()
        job = Task {
            let result = await assistant.perform(request, on: source, subject: subject, known: known,
                                                 senderFacts: isTemplate ? nil : senderFacts,
                                                 brief: place.brief(senderName: profileStore.profile.name),
                                                 attempt: attempt)
            guard !Task.isCancelled else { return }
            if let result {
                candidate = result
                tab = .changes
                prompt = ""
                refinement = ""
                Haptics.arrival()
                withAnimation { stage = .review }
            } else {
                Haptics.warning()
                withAnimation { stage = candidate.isEmpty ? .compose : .review }
            }
        }
    }

    private func accept() {
        Haptics.success()
        assistant.accepted(replacing: original)
        text = candidate
        onApplied()
        burst = .now
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 950))
            dismiss()
        }
    }

    private func close() {
        job?.cancel()
        dismiss()
    }
}
