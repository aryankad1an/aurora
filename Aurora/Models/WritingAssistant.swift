import Foundation
import FoundationModels
import Observation

/// What the user asked the model to do.
enum WritingRequest: Equatable {
    case preset(WritingAction)
    /// The user's own instruction, in their words.
    case custom(String)
    /// A first draft of a company line, from what the student says it should say
    /// (nil: from the company's name and sector alone).
    case draft(notes: String?)

    var title: String {
        switch self {
        case .preset(let action): action.title
        case .custom(let text): text
        case .draft(let notes):
            notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Write one for me"
        }
    }
}

/// Rewrites, proofreads and drafts text with Apple's larger cloud model — the one
/// Siri and Apple Intelligence hand their harder requests to — through Private
/// Cloud Compute, once the app holds Apple's entitlement for it (see `usesCloud`);
/// until then with the on-device model, which is weaker: it can drop greetings,
/// ignore notes and copy its examples. Private Cloud Compute keeps the request
/// private to Apple's servers and isn't stored.
///
/// One assistant per editor: it streams the answer as it's written, and
/// remembers the text before an accepted change so the editor can offer Undo.
@MainActor
@Observable
final class WritingAssistant {
    private(set) var isWorking = false
    /// The answer so far, while one is being written.
    private(set) var streamed = ""
    /// The text as it was before the last accepted change, while Undo is on offer.
    private(set) var previous: String?
    /// A reason the last request didn't go through, shown in the sheet.
    var failure: String?
    /// Said with an answer that came another way than asked: the shortcut
    /// didn't answer, so the on-device model wrote it.
    private(set) var notice: String?
    /// Whether the request is out with the shortcut, with nothing to stream.
    private(set) var isInShortcuts = false
    /// Set once the shortcut has failed during a request, so its second round
    /// stays on the device rather than going back to Shortcuts.
    private var shortcutFailed = false

    /// The cloud model, shared: creating one is cheap, but there's no reason to.
    static let model = PrivateCloudComputeLanguageModel()

    /// Whether requests go to the cloud model. It needs a managed entitlement Apple
    /// grants on request, and without it Foundation Models doesn't throw: it stops
    /// the app with an assertion on the first request. So the app checks its own
    /// signature, and until the entitlement is there it writes on the device.
    static let usesCloud: Bool = {
        #if targetEnvironment(simulator)
        // The Simulator can't reach Private Cloud Compute, entitlement or not.
        return false
        #else
        return Entitlements.allowsPrivateCloudCompute
        #endif
    }()

    /// Whether requests go to the user's Aurora Writer shortcut, which can use the
    /// cloud model through Shortcuts' Use Model action (see `ShortcutsWriter`).
    /// Only without the entitlement; the on-device model stands in when the
    /// shortcut doesn't answer.
    static var viaShortcuts: Bool { !usesCloud && ShortcutsWriter.isEnabled }

    /// How long an answer may take before the request is given up. A cloud call
    /// that never answers otherwise leaves the sheet spinning for good.
    static let timeout: Duration = .seconds(45)

    /// Nil when the model can be used; otherwise why not, in words for the user.
    static var unavailableReason: String? {
        // The shortcut's model is the shortcut's business; when it fails, the
        // on-device model's own reason is given then.
        if viaShortcuts { return nil }
        guard usesCloud else {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This iPhone doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to use this."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still getting ready. Try again in a little while."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        switch model.availability {
        case .available:
            if model.quotaUsage.isLimitReached { return quotaMessage(resetDate: model.quotaUsage.resetDate) }
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone can't use Apple Intelligence's cloud model."
        case .unavailable(.systemNotReady):
            return "Apple Intelligence is still getting ready. Make sure it's turned on in Settings, then try again in a little while."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    /// Whether the account is close to its share of cloud requests, for a quiet
    /// note in the sheet before it runs out.
    static var isApproachingLimit: Bool {
        guard usesCloud else { return false }
        if case .belowLimit(let below) = model.quotaUsage.status { return below.isApproachingLimit }
        return false
    }

    private static func quotaMessage(resetDate: Date?) -> String {
        guard let resetDate else { return "You've used Apple Intelligence's cloud requests for now. Try again later." }
        return "You've used Apple Intelligence's cloud requests for now. They're back "
            + resetDate.formatted(.relative(presentation: .named)) + "."
    }

    /// Carry out `request` on `text`. Returns the new text, or nil when the model
    /// couldn't (see `failure`), was cancelled, or its answer would have damaged a
    /// placeholder even after a second try.
    ///
    /// - Parameters:
    ///   - known: the placeholders the app understands, which the model may add
    ///     when asked and must otherwise leave alone. Non-empty means `text` is a
    ///     template.
    ///   - senderFacts: the sender's real details, for text that is already
    ///     filled in and so has no placeholders to stand for them.
    ///   - brief: what the text is and where it goes (see `WritingPlace`), put
    ///     ahead of the request so the model writes for that spot.
    ///   - attempt: how many times this same request has already been tried. The
    ///     model is nudged to vary more each time, or "Try again" would give back
    ///     the same words.
    func perform(_ request: WritingRequest, on text: String, subject: DraftSubject? = nil,
                 known: [String] = [], senderFacts: String? = nil, brief: String? = nil,
                 attempt: Int = 0) async -> String? {
        failure = nil
        notice = nil
        shortcutFailed = false
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt: String
        let instructions: String
        var temperature: Double
        var checking: String?
        // The company line is a sentence or two for the middle of a mail, which the
        // editing rules would turn into a whole mail with a greeting and sign-off.
        let isLine = subject != nil
        switch request {
        case .preset(let action):
            guard !original.isEmpty else { return empty() }
            prompt = action.prompt(for: original, isLine: isLine)
            instructions = WritingAction.rules(known: known, senderFacts: senderFacts, isLine: isLine)
            temperature = action.temperature
            checking = original
        case .custom(let instruction):
            guard !original.isEmpty else { return empty() }
            prompt = WritingAction.editPrompt(instruction, for: original, isLine: isLine)
            instructions = WritingAction.rules(known: known, senderFacts: senderFacts, isLine: isLine)
            temperature = 0.3
            checking = original
        case .draft(let notes):
            guard let subject else { return nil }
            prompt = WritingAction.draftPrompt(company: subject.company, sector: subject.sector, notes: notes)
            let hasNotes = !(notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            instructions = WritingAction.draftRules(hasNotes: hasNotes)
            temperature = 0.6
        }
        if let brief, !brief.isEmpty { prompt = brief + "\n\n" + prompt }
        temperature = min(temperature + 0.2 * Double(attempt), 1.0)
        if let reason = Self.unavailableReason {
            failure = reason
            return nil
        }
        isWorking = true
        streamed = ""
        defer { isWorking = false }
        do {
            var reminder = ""
            // A second try, once, when the answer lost or renamed a placeholder: the
            // reminder names exactly which ones must be there.
            for round in 0..<2 {
                let reply = try await write(prompt + reminder, instructions: instructions, temperature: temperature,
                                            title: request.title, attempt: attempt)
                var result = WritingAction.cleaned(reply)
                if case .draft = request { result = WritingAction.cleanedLine(result) }
                else if isLine { result = WritingAction.cleanedLine(result) }
                guard !result.isEmpty else {
                    failure = "Apple Intelligence sent back nothing. Try again."
                    return nil
                }
                guard let checking else { return result }
                if WritingAction.keepsPlaceholders(original: checking, result: result, allowing: known) { return result }
                if round == 0 {
                    let needed = WritingAction.placeholders(in: checking)
                    reminder = "\n\nYour last answer changed the placeholders. The email must still contain exactly these, written as they are: "
                        + (needed.isEmpty ? "(none)" : needed.joined(separator: " "))
                    streamed = ""
                    temperature = max(temperature - 0.2, 0.1)
                }
            }
            failure = "That change would have altered a placeholder such as {Receiver-Name}, so it wasn't applied. Try again."
            return nil
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure:
                failure = "Couldn't reach Apple Intelligence. Check your connection and try again."
            case .quotaLimitReached(let limit):
                failure = Self.quotaMessage(resetDate: limit.resetDate)
            case .serviceUnavailable:
                failure = "Apple Intelligence's cloud model is busy right now. Try again in a moment."
            @unknown default:
                failure = "Apple Intelligence couldn't do that. Try again."
            }
            return nil
        } catch let error as ShortcutsWriter.Failure {
            failure = error.message
            return nil
        } catch is TimedOut {
            failure = "Apple Intelligence didn't answer in time. Check your connection and try again."
            return nil
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                failure = "That's too long for Apple Intelligence to handle in one go."
            case .guardrailViolation, .refusal:
                failure = "Apple Intelligence couldn't work with that text."
            case .unsupportedLanguageOrLocale:
                failure = "Apple Intelligence doesn't support this language yet."
            case .rateLimited:
                failure = "Apple Intelligence is busy. Try again in a moment."
            default:
                failure = "Apple Intelligence couldn't do that. Try again."
            }
            return nil
        } catch {
            if !error.isCancellation { failure = "Apple Intelligence couldn't do that. Try again." }
            return nil
        }
    }

    /// Note that `old` was replaced by an accepted change, so it can be undone.
    func accepted(replacing old: String) { previous = old }

    /// Put back the text from before the last accepted change.
    func undo() -> String? {
        defer { previous = nil }
        return previous
    }

    func forgetUndo() { previous = nil }

    private func empty() -> String? {
        failure = "Write something first, then ask for a change."
        return nil
    }

    private struct TimedOut: Error {}

    /// Ask the shortcut when it's on, and the model on the device when it isn't
    /// or doesn't answer (with `notice` saying so).
    private func write(_ prompt: String, instructions: String, temperature: Double,
                       title: String, attempt: Int) async throws -> String {
        guard Self.viaShortcuts, !shortcutFailed else {
            return try await writeHere(prompt, instructions: instructions, temperature: temperature)
        }
        // Use Model takes a single request, so the rules go first. It has no
        // temperature, so Try Again asks for a different version in words.
        let variation = attempt > 0 ? "\n\nWrite a noticeably different version from your previous answers." : ""
        isInShortcuts = true
        defer { isInShortcuts = false }
        do {
            let reply = try await ShortcutsWriter.shared.ask(instructions + "\n\n" + prompt + variation, title: title)
            streamed = reply
            return reply
        } catch ShortcutsWriter.Failure.cancelled {
            throw CancellationError()
        } catch let error as ShortcutsWriter.Failure {
            guard SystemLanguageModel.default.isAvailable else { throw error }
            shortcutFailed = true
            isInShortcuts = false
            notice = error.message + " This was written by the smaller model on your iPhone instead."
            return try await writeHere(prompt, instructions: instructions, temperature: temperature)
        }
    }

    /// Ask the model, publishing the answer in `streamed` as it arrives, and give up
    /// after `timeout` without an answer.
    private func writeHere(_ prompt: String, instructions: String, temperature: Double) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [self] in
                let session = Self.usesCloud
                    ? LanguageModelSession(model: Self.model, instructions: instructions)
                    : LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                var latest = ""
                for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: temperature)) {
                    latest = snapshot.content
                    self.streamed = latest
                }
                return latest
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
