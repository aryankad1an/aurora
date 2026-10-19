import SwiftUI

/// What the assistant is told about a company when asked to write a line for it.
struct DraftSubject {
    let company: String
    let sector: String?
}

/// The sparkles button: Apple Intelligence's cloud model (see `WritingAssistant`)
/// on the text it's bound to — quick fixes, the user's own instruction, and, when
/// given a `subject`, a first draft — with every answer shown as a comparison and
/// applied only once approved. The system's own Writing Tools stay one tap away
/// in the same sheet, through `writingTools`.
struct WritingAssistButton: View {
    @Binding var text: String
    var subject: DraftSubject?
    /// Whether the text is a template, where the model may be asked to add
    /// placeholders such as {Receiver-Name}.
    var isTemplate = false
    /// The paired editor, for opening the system's Writing Tools on it instead.
    var writingTools: WritingToolsTarget?
    /// Called when an approved change has been written into `text`.
    var onApplied: () -> Void = {}

    @State private var assistant = WritingAssistant()
    /// Set when the sheet was closed to open Writing Tools, which waits for it to go.
    @State private var openWritingToolsAfter = false
    @State private var showing = false
    /// The text an accepted change left behind, to tell whether it has been
    /// edited since (after which Undo would throw those edits away).
    @State private var applied: String?

    var body: some View {
        Button {
            Haptics.tap()
            showing = true
        } label: {
            Image(systemName: "sparkles")
                .symbolEffect(.bounce, value: assistant.previous)
        }
        .accessibilityLabel("Writing help")
        .accessibilityHint("Apple Intelligence: proofread, rewrite, or tell it what to change")
        .sheet(isPresented: $showing, onDismiss: {
            guard openWritingToolsAfter else { return }
            openWritingToolsAfter = false
            Task { await writingTools?.open() }
        }) {
            WritingAssistSheet(text: $text, subject: subject, isTemplate: isTemplate,
                               assistant: assistant, onApplied: {
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

/// The writing-help sheet: ask → watch it work → review what changed → approve.
struct WritingAssistSheet: View {
    @Binding var text: String
    let subject: DraftSubject?
    let isTemplate: Bool
    let assistant: WritingAssistant
    let onApplied: () -> Void
    /// Closes the sheet and opens the system's Writing Tools on the text instead.
    var onUseWritingTools: (() -> Void)?

    private enum Stage: Equatable { case compose, working, review }
    private enum Tab: Hashable { case changes, result }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ProfileStore.self) private var profileStore
    @State private var stage = Stage.compose
    /// The text as the sheet opened, which every comparison is made against.
    @State private var original = ""
    /// The answer under review.
    @State private var candidate = ""
    /// What the answer was made from, and what was asked, for Try Again.
    @State private var lastSource = ""
    @State private var lastRequest: WritingRequest?
    /// How many times the same request has been asked again, so each Try Again
    /// varies more.
    @State private var attempts = 0
    @State private var prompt = ""
    @State private var refinement = ""
    @State private var tab = Tab.changes
    @State private var job: Task<Void, Never>?
    @State private var burst: Date?
    @State private var loaded = false
    @FocusState private var promptFocused: Bool
    @FocusState private var refineFocused: Bool

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
                guard !loaded else { return }
                loaded = true
                original = text
            }
            .messageAlert("Apple Intelligence", message: assistant.failure) { assistant.failure = nil }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(stage == .working)
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
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(hasText ? "Tell it what to do" : (subject == nil ? "Tell it what to do" : "What should it say?"))
                        promptField(text: $prompt, focus: $promptFocused,
                                    placeholder: hasText ? "e.g. Mention I'm a final-year student"
                                                         : (subject == nil ? "Nothing to change yet"
                                                                           : "e.g. I built a project using their API")) {
                            // With nothing written yet, what's typed is what the line should
                            // say, not an instruction about text that doesn't exist.
                            run(hasText ? .custom(prompt) : .draft(notes: prompt), from: original)
                        }
                        .disabled(!hasText && subject == nil)
                        if hasText { suggestions }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(hasText ? "Or pick a quick fix" : "Start")
                        quickActions
                    }

                    if hasText {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("Your text")
                            sourceCard(glow: false)
                        }
                    }

                    if assistant.previous != nil { undoRow }
                    if WritingAssistant.isApproachingLimit {
                        Label("You're close to your share of Apple Intelligence cloud requests for now.",
                              systemImage: "gauge.with.dots.needle.67percent")
                            .font(.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                    if hasText { writingToolsRow }
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
                Text("Apple's larger cloud model, the one Siri uses. Private Cloud Compute keeps your text private to the request.")
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

    /// The text the request will work on, as a quiet card.
    private func sourceCard(glow: Bool) -> some View {
        Group {
            if hasText {
                Text(original)
                    .font(.callout)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
            } else {
                Text("Nothing written yet.")
                    .font(.callout)
                    .foregroundStyle(Color.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panel(radius: Theme.Radius.inner)
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

    private var suggestions: some View {
        let ideas = isTemplate
            ? ["Add a greeting with their name", "Mention I'm a final-year student", "End with a thank-you"]
            : ["Make it sound more confident", "Mention I'm a final-year student", "Add a thank-you line"]
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
                        .background(Color.paperSunken, in: Capsule())
                        .foregroundStyle(Color.inkMuted)
                }
                .buttonStyle(BouncyPress(scale: 0.94))
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
            .padding(.horizontal, Theme.Space.gutter)

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                Text(assistant.streamed.isEmpty ? "Reading…" : "Writing…")
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
                        summary(diff)
                    }

                    SegmentedSelector(segments: [(Tab.changes, "Changes"), (Tab.result, "Result")], selection: $tab)

                    Group {
                        if tab == .changes {
                            Text(diff.attributed)
                        } else {
                            Text(candidate)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .panel()
                    .overlay { AIGlowBorder(isTurning: false, halo: 0.10).opacity(0.7) }
                    .contentTransition(.opacity)

                    if tab == .changes, diff.hasChanges { legend(diff) }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Not quite? Say what to adjust")
                        promptField(text: $refinement, focus: $refineFocused,
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

    private func summary(_ diff: TextDiff) -> some View {
        Group {
            if diff.hasChanges {
                HStack(spacing: 8) {
                    Text("+\(diff.addedWords)").foregroundStyle(Color.olive)
                    Text("−\(diff.removedWords)").foregroundStyle(Color.danger)
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            } else {
                Text("No changes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    private func legend(_ diff: TextDiff) -> some View {
        HStack(spacing: 14) {
            if diff.addedWords > 0 { legendKey("Added", color: Color.olive) }
            if diff.removedWords > 0 { legendKey("Removed", color: Color.danger) }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(Color.inkMuted)
    }

    private func legendKey(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.35)).frame(width: 12, height: 12)
            Text(title)
        }
    }

    private func reviewBar(_ diff: TextDiff) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
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
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, 10)
        .background(.bar)
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
                                                 senderFacts: isTemplate ? nil : senderFacts, attempt: attempt)
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
