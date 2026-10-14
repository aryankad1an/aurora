import Foundation
import FoundationModels
import Observation

/// Rewrites, proofreads and drafts text with Apple's on-device model (the
/// Foundation Models framework). Nothing leaves the phone, which matters for
/// a mail that names a recruiter. One assistant per editor: it remembers the
/// text before the last change so the editor can offer Undo.
@MainActor
@Observable
final class WritingAssistant {
    private(set) var isWorking = false
    /// The text as it was before the last AI change, while Undo is on offer.
    private(set) var previous: String?
    /// A reason the last request didn't go through, for an alert.
    var failure: String?

    /// Nil when the model can be used; otherwise why not, in words for the user.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to use this."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again in a little while."
        case .unavailable:
            "Apple Intelligence isn't available right now."
        }
    }

    /// Apply `action` to `text`. Returns the new text, or nil when the model
    /// couldn't (see `failure`) or its answer would have damaged a placeholder.
    func apply(_ action: WritingAction, to text: String) async -> String? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            failure = "Write something first, then ask for a change."
            return nil
        }
        return await run(prompt: action.prompt(for: original), checking: original, replacing: text)
    }

    /// Draft a line about a company from what the catalog knows of it.
    func draft(company: String, sector: String?, website: String?, replacing text: String) async -> String? {
        await run(prompt: WritingAction.draftPrompt(company: company, sector: sector, website: website),
                  checking: nil, replacing: text)
    }

    /// Put back the text from before the last change.
    func undo() -> String? {
        defer { previous = nil }
        return previous
    }

    func forgetUndo() { previous = nil }

    private func run(prompt: String, checking original: String?, replacing text: String) async -> String? {
        if let reason = Self.unavailableReason {
            failure = reason
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let session = LanguageModelSession(instructions: WritingAction.rules)
            let reply = try await session.respond(to: prompt).content
            let result = WritingAction.cleaned(reply)
            guard !result.isEmpty else {
                failure = "Apple Intelligence sent back nothing. Try again."
                return nil
            }
            if let original, !WritingAction.keepsPlaceholders(original: original, result: result) {
                failure = "That change would have altered a placeholder such as {Receiver-Name}, so it wasn't applied. Try again."
                return nil
            }
            previous = text
            return result
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
}
