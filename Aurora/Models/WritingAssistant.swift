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

/// Rewrites, proofreads and drafts text with Apple's on-device model (the
/// Foundation Models framework). Nothing leaves the phone, which matters for
/// a mail that names a recruiter. One assistant per editor: it streams the
/// answer as it's written, and remembers the text before an accepted change so
/// the editor can offer Undo.
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

    /// Nil when the model can be used; otherwise why not, in words for the user.
    static var unavailableReason: String? {
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
    ///   - attempt: how many times this same request has already been tried. The
    ///     model is nudged to vary more each time, or "Try again" would give back
    ///     the same words.
    func perform(_ request: WritingRequest, on text: String, subject: DraftSubject? = nil,
                 known: [String] = [], senderFacts: String? = nil, attempt: Int = 0) async -> String? {
        failure = nil
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
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
                let reply = try await write(prompt + reminder, instructions: instructions, temperature: temperature)
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

    /// Ask the model, publishing the answer in `streamed` as it arrives.
    private func write(_ prompt: String, instructions: String, temperature: Double) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        var latest = ""
        for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: temperature)) {
            latest = snapshot.content
            streamed = latest
        }
        return latest
    }
}
