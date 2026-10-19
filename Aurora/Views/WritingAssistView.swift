import SwiftUI

/// What the assistant is told about a company when asked to write a line for it.
struct DraftSubject {
    let company: String
    let sector: String?
    /// What the student studies or does, from their profile.
    var student: String?
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

    /// The company a line is for, with what the student studies or does, so a
    /// line written from nothing can say why them.
    private var subject: DraftSubject? {
        guard var subject = place.draftSubject else { return nil }
        let profile = profileStore.profile
        var about: [String] = []
        if profile.isStudying, !profile.college.isEmpty { about.append("studies at \(profile.college)") }
        if profile.isWorking, !profile.company.isEmpty {
            about.append("works at \(profile.company)" + (profile.position.isEmpty ? "" : " as \(profile.position)"))
        }
        subject.student = about.isEmpty ? nil : about.joined(separator: "; ")
        return subject
    }
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

    /// What the send button does with nothing typed: a company line is written
    /// whole from everything the model is told; other text is polished for
    /// where it goes. Nil when there's nothing to work on.
    private var emptyRequest: WritingRequest? {
        if subject != nil { return .draft(notes: nil) }
        return hasText ? .polish : nil
    }

    private var emptyLabel: String {
        subject == nil ? "Polish" : (hasText ? "Write a new one" : "Write it for me")
    }

    private var composePlaceholder: String {
        switch (subject != nil, hasText) {
        case (true, false): "Anything it should mention? Optional"
        case (true, true): "Say what to change, or write a new one"
        case (false, true): "Say what to change, or just polish it"
        case (false, false): "Nothing to change yet"
        }
    }

    private var compose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contextCard

                if let unavailable {
                    unavailableCard(unavailable)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        composer(text: $session.prompt, focus: $promptFocused, placeholder: composePlaceholder,
                                 emptyLabel: emptyRequest == nil ? nil : emptyLabel, showsModel: true) {
                            let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            if typed.isEmpty {
                                if let emptyRequest { run(emptyRequest, from: original) }
                            } else {
                                // With nothing written yet, what's typed is what the line should
                                // say, not an instruction about text that doesn't exist.
                                run(hasText ? .custom(typed) : .draft(notes: typed), from: original)
                            }
                        }
                        .disabled(!hasText && subject == nil)
                        if hasText || subject != nil { suggestions }
                    }

                    if hasText {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(title: "Quick fixes", systemImage: "wand.and.stars")
                            quickFixes
                        }
                    }
                }

                footer
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// What the text is, who it's for, and what else the model is told, so
    /// it's plain what the answer is written for.
    private var contextCard: some View {
        let summary = place.summary
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: summary.systemImage, size: Theme.Avatar.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.kind)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Color.inkMuted)
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(AIStyle.linear)
                    .frame(width: 3)
                    .opacity(hasText ? 1 : 0.35)
                Text(hasText ? original : "Nothing written yet.")
                    .font(.callout)
                    .foregroundStyle(hasText ? Color.ink : Color.inkFaint)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

            let facts = place.facts(hasProfile: senderFacts != nil)
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(facts, id: \.text) { fact in
                        Label {
                            Text(fact.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: fact.systemImage)
                                .foregroundStyle(Color.clay)
                                .frame(width: factIconWidth)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel(radius: Theme.Radius.inner)
        .accessibilityElement(children: .combine)
    }

    /// The preset fixes as tiles: three across, two at large text, and a list
    /// at accessibility sizes, where a tile's icon sits beside its name.
    private var quickFixes: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : (typeSize >= .xxLarge ? 2 : 3)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(WritingAction.allCases) { action in
                Button {
                    Haptics.tap()
                    run(.preset(action), from: original)
                } label: {
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
                    layout {
                        Image(systemName: action.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.clay)
                        Text(action.shortTitle)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
                        if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 52 : 64)
                    .padding(.horizontal, 10)
                    .contentShape(.rect)
                    .panel(radius: Theme.Radius.inner)
                }
                .buttonStyle(BouncyPress(scale: 0.94))
            }
        }
    }

    /// Prompts written out in full: a tap puts one in the box to send as it is or
    /// reword first.
    private var suggestions: some View {
        let ideas = PromptIdeas.ideas(for: place.ideaKind, text: original, profile: profileStore.profile)
        return AdaptiveFlow(spacing: 6) {
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

    /// Which model answers, as a small badge in the composer.
    private var modelBadge: some View {
        let (image, name) = WritingAssistant.usesCloud ? ("cloud", "Private Cloud Compute")
            : viaShortcuts ? ("square.2.layers.3d", ShortcutsWriter.shortcutName)
            : ("iphone", "On iPhone")
        return Label(name, systemImage: image)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.inkMuted)
            .lineLimit(1)
            .accessibilityLabel("Model: \(name)")
    }

    /// Undo, the system's Writing Tools and the Shortcuts route, as small chips
    /// under a one-line note on the model.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if WritingAssistant.isApproachingLimit {
                Label("You're close to your share of Apple Intelligence cloud requests for now.",
                      systemImage: "gauge.with.dots.needle.67percent")
            } else if !WritingAssistant.usesCloud, !viaShortcuts, unavailable == nil {
                Label("The model on your iPhone is smaller than Siri's, so check what it changes.",
                      systemImage: "info.circle")
            }
            AdaptiveFlow(spacing: 8) {
                if assistant.previous != nil {
                    footerChip("Undo last change", systemImage: "arrow.uturn.backward") {
                        guard let old = assistant.undo() else { return }
                        text = old
                        original = old
                        onApplied()
                    }
                    .transition(.liquid)
                }
                if hasText, let onUseWritingTools {
                    footerChip("Writing Tools", systemImage: "pencil.and.scribble", action: onUseWritingTools)
                }
                if !WritingAssistant.usesCloud {
                    footerChip(viaShortcuts ? "\(ShortcutsWriter.shortcutName): on" : "Siri's model via Shortcuts",
                               systemImage: "square.2.layers.3d") { session.showingShortcutSetup = true }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.inkMuted)
    }

    private func footerChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.clay.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.clay)
        }
        .buttonStyle(BouncyPress(scale: 0.94))
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

    /// A text box with the send button under it, ringed in colour that turns
    /// while it has focus. Left empty, the button says what it will do instead
    /// (`emptyLabel`); nil means it needs something typed.
    private func composer(text: Binding<String>, focus: FocusState<Bool>.Binding, placeholder: String,
                          emptyLabel: String?, showsModel: Bool = false,
                          onSend: @escaping () -> Void) -> some View {
        let typed = !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ready = typed || emptyLabel != nil
        return VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(2...5)
                .font(.subheadline)
                .foregroundStyle(Color.ink)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit { if ready { onSend() } }
            HStack(spacing: 8) {
                if showsModel { modelBadge }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    onSend()
                } label: {
                    Group {
                        if !typed, let emptyLabel {
                            Label(emptyLabel, systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .background(Color.clay, in: Capsule())
                                .foregroundStyle(Color.white)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 34, height: 34)
                                .background(ready ? Color.clay : Color.inkFaint.opacity(0.4), in: Circle())
                                .foregroundStyle(Color.white)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.Motion.snappy, value: typed)
                }
                .buttonStyle(BouncyPress(scale: 0.92))
                .disabled(!ready)
                .accessibilityLabel(!typed ? (emptyLabel ?? "Send") : "Send")
            }
        }
        .padding(14)
        .panel(radius: 20)
        .overlay {
            AIGlowBorder(cornerRadius: 20, lineWidth: 1.5, isTurning: focus.wrappedValue, halo: 0.12)
                .opacity(focus.wrappedValue ? 1 : 0.35)
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

                    composer(text: $session.refinement, focus: $refineFocused,
                             placeholder: "Not quite? Say what to adjust", emptyLabel: "Polish") {
                        let typed = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
                        run(typed.isEmpty ? .polish : .custom(typed), from: candidate)
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
