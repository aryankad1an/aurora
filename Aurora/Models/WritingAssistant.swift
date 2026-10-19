import Foundation
import Observation

/// What the user asked the model to do.
enum WritingRequest: Equatable {
    case preset(WritingAction)
    /// The user's own instruction, in their words.
    case custom(String)
    /// An instruction left empty: tidy the text up for where it goes.
    case polish
    /// A first draft of a company line, from what the student says it should say
    /// (nil: from the company's name and sector alone).
    case draft(notes: String?)

    var title: String {
        switch self {
        case .preset(let action): action.title
        case .custom(let text): text
        case .polish: "Polish"
        case .draft(let notes):
            notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Write one for me"
        }
    }
}

/// Rewrites, proofreads and drafts text through the user's Aurora Writer
/// shortcut (see `ShortcutsWriter`), the app's only source of written text: the
/// shortcut's Use Model action does the writing, and the answer comes back here.
///
/// One assistant per editor: it holds the answer, and remembers the text before
/// an accepted change so the editor can offer Undo.
@MainActor
@Observable
final class WritingAssistant {
    private(set) var isWorking = false
    /// The answer, once the shortcut has sent it back.
    private(set) var streamed = ""
    /// The text as it was before the last accepted change, while Undo is on offer.
    private(set) var previous: String?
    /// A reason the last request didn't go through, shown in the sheet.
    var failure: String?
    /// Whether the request is out with the shortcut.
    private(set) var isInShortcuts = false

    /// Whether Aurora Writer is connected: set up, tested and switched on.
    static var isConnected: Bool { ShortcutsWriter.isEnabled }

    /// Nil when writing help can be used; otherwise why not, in words for the user.
    static var unavailableReason: String? {
        isConnected ? nil : "Connect \(ShortcutsWriter.shortcutName) to use writing help."
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
    ///     shortcut is asked for a different version, or "Try again" would give
    ///     back the same words.
    func perform(_ request: WritingRequest, on text: String, subject: DraftSubject? = nil,
                 known: [String] = [], senderFacts: String? = nil, brief: String? = nil,
                 attempt: Int = 0) async -> String? {
        failure = nil
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt: String
        let instructions: String
        var checking: String?
        // The company line is a sentence or two for the middle of a mail, which the
        // editing rules would turn into a whole mail with a greeting and sign-off.
        let isLine = subject != nil
        switch request {
        case .preset(let action):
            guard !original.isEmpty else { return empty() }
            prompt = action.prompt(for: original, isLine: isLine)
            instructions = WritingAction.rules(known: known, senderFacts: senderFacts, isLine: isLine)
            checking = original
        case .custom(let instruction):
            guard !original.isEmpty else { return empty() }
            prompt = WritingAction.editPrompt(instruction, for: original, isLine: isLine)
            instructions = WritingAction.rules(known: known, senderFacts: senderFacts, isLine: isLine)
            checking = original
        case .polish:
            guard !original.isEmpty else { return empty() }
            prompt = WritingAction.editPrompt(WritingAction.polishInstruction, for: original, isLine: isLine)
            instructions = WritingAction.rules(known: known, senderFacts: senderFacts, isLine: isLine)
            checking = original
        case .draft(let notes):
            guard let subject else { return nil }
            prompt = WritingAction.draftPrompt(company: subject.company, sector: subject.sector, notes: notes,
                                               student: subject.student)
            let hasNotes = !(notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            instructions = WritingAction.draftRules(hasNotes: hasNotes, hasStudent: subject.student != nil)
        }
        if let brief, !brief.isEmpty { prompt = brief + "\n\n" + prompt }
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
                let reply = try await write(prompt + reminder, instructions: instructions,
                                            title: request.title, attempt: attempt)
                var result = WritingAction.cleaned(reply)
                if case .draft = request { result = WritingAction.cleanedLine(result) }
                else if isLine { result = WritingAction.cleanedLine(result) }
                guard !result.isEmpty else {
                    failure = "\(ShortcutsWriter.shortcutName) sent back nothing. Try again."
                    return nil
                }
                guard let checking else { return result }
                if WritingAction.keepsPlaceholders(original: checking, result: result, allowing: known) { return result }
                if round == 0 {
                    let needed = WritingAction.placeholders(in: checking)
                    reminder = "\n\nYour last answer changed the placeholders. The email must still contain exactly these, written as they are: "
                        + (needed.isEmpty ? "(none)" : needed.joined(separator: " "))
                    streamed = ""
                }
            }
            failure = "That change would have altered a placeholder such as {Receiver-Name}, so it wasn't applied. Try again."
            return nil
        } catch let error as ShortcutsWriter.Failure {
            failure = error.message
            return nil
        } catch {
            if !error.isCancellation { failure = "\(ShortcutsWriter.shortcutName) couldn't do that. Try again." }
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

    /// Hand the request to the shortcut. Use Model takes a single request, so the
    /// rules go first, and Try Again asks for a different
    /// version in words.
    private func write(_ prompt: String, instructions: String, title: String, attempt: Int) async throws -> String {
        let variation = attempt > 0 ? "\n\nWrite a noticeably different version from your previous answers." : ""
        isInShortcuts = true
        defer { isInShortcuts = false }
        do {
            let reply = try await ShortcutsWriter.shared.ask(instructions + "\n\n" + prompt + variation, title: title)
            streamed = reply
            return reply
        } catch ShortcutsWriter.Failure.cancelled {
            throw CancellationError()
        }
    }
}
