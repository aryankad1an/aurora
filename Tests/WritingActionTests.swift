import Foundation

// The rules around writing help: what a reply is cleaned of, and when a rewrite
// is refused for having touched a {placeholder}. The call to the Aurora Writer
// shortcut itself isn't exercised here.
//
//   swiftc -parse-as-library Aurora/Models/WritingAction.swift Aurora/Models/TextDiff.swift \
//     Tests/WritingActionTests.swift -o /tmp/wa && /tmp/wa

@main
struct WritingActionTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() {
        let original = "Hi {Receiver-Name}, I like {Receiver-Company}. {Company-Personalised}"
        expect(WritingAction.keepsPlaceholders(original: original,
                                               result: "Hello {Receiver-Name}! {Company-Personalised} I admire {Receiver-Company}."),
               true, "reordered placeholders are fine")
        expect(WritingAction.keepsPlaceholders(original: original,
                                               result: "Hi {Receiver-Name}, I like {Receiver-Company}."),
               false, "a dropped placeholder is refused")
        expect(WritingAction.keepsPlaceholders(original: original,
                                               result: "Hi {Receiver Name}, I like {Receiver-Company}. {Company-Personalised}"),
               false, "a renamed placeholder is refused")
        expect(WritingAction.keepsPlaceholders(original: "Plain text.", result: "Plain text {Sender-Name}."),
               false, "an invented placeholder is refused")
        expect(WritingAction.keepsPlaceholders(original: "Hi,", result: "Hi {Receiver-Name},", allowing: ["{Receiver-Name}"]),
               true, "adding a known placeholder is allowed when asked for")
        expect(WritingAction.keepsPlaceholders(original: "Hi,", result: "Hi {Reciever-Name},", allowing: ["{Receiver-Name}"]),
               false, "adding a misspelt one is not")
        expect(WritingAction.keepsPlaceholders(original: "{A} and {A}", result: "{A}", allowing: ["{A}"]),
               false, "dropping one of two copies is refused")
        expect(WritingAction.keepsPlaceholders(original: "No tokens.", result: "No tokens at all."),
               true, "text without placeholders passes")

        expect(WritingAction.cleaned("  Hello there.\n"), "Hello there.", "whitespace trimmed")
        expect(WritingAction.cleaned("\"Hello there.\""), "Hello there.", "wrapping quotes removed")
        expect(WritingAction.cleaned("“Hello there.”"), "Hello there.", "wrapping curly quotes removed")
        expect(WritingAction.cleaned("\"Hi,\" she said, \"bye.\""), "\"Hi,\" she said, \"bye.\"", "inner quotes kept")
        expect(WritingAction.cleaned("```\nHello there.\n```"), "Hello there.", "code fence removed")
        expect(WritingAction.cleaned("```text\nHello there.\n```"), "Hello there.", "labelled code fence removed")

        // Prompts and checks around the model
        let line = WritingAction.draftPrompt(company: "Stripe", sector: "Financial technology", notes: nil)
        expect(line, "Company: Stripe\nSector: Financial technology\nReply:", "a draft prompt names the company and sector only")
        let noted = WritingAction.draftPrompt(company: "Stripe", sector: nil, notes: "  I built a payments demo  ")
        expect(noted, "Company: Stripe\nNotes from the student: I built a payments demo\nReply:", "notes are trimmed and included")
        expect(WritingAction.draftPrompt(company: "Stripe", sector: nil, notes: "   "), "Company: Stripe\nReply:", "blank notes are left out")
        expect(WritingAction.draftRules(hasNotes: true).contains("Notes from the student"), true, "notes rules show notes")
        expect(WritingAction.draftRules(hasNotes: true).contains("Rippling"), false, "notes rules carry no generic examples to copy")
        expect(WritingAction.draftRules(hasNotes: false).contains("Rippling"), true, "no-notes rules carry generic examples")
        expect(WritingAction.rules().contains("{Resume-Link}"), false, "a mail that is already filled in is told no placeholders")
        expect(WritingAction.rules(known: ["{Resume-Link}"]).contains("{Resume-Link}"), true, "a template is told its placeholders")
        expect(WritingAction.rules(senderFacts: "studies at IIT Delhi").contains("studies at IIT Delhi"), true, "sender facts reach the rules")
        expect(WritingAction.rules(isLine: true).contains("greeting"), true, "a company line is told not to add a greeting")
        expect(WritingAction.editPrompt("Make the email shorter.", for: "A.", isLine: true), "Instruction: Make the sentences shorter.\n\nSentences:\nA.", "a line's instruction speaks of sentences")
        expect(WritingAction.editPrompt("Make the email shorter.", for: "A."), "Instruction: Make the email shorter.\n\nEmail:\nA.", "a mail's instruction speaks of the email")
        expect(WritingAction.cleanedLine("Hi Priya,\nI love Stripe's work.\nBest regards,\nAryan"), "I love Stripe's work.", "a greeting and sign-off are stripped from a line")
        expect(WritingAction.cleanedLine("Thanks to its API, I built a payments demo."), "Thanks to its API, I built a payments demo.", "a sentence that starts with Thanks is kept")
        expect(WritingAction.cleanedLine("I follow {company-name} closely."), "", "a line with invented braces is refused")
        expect(WritingAction.cleaned("Reply: I love Stripe."), "I love Stripe.", "an echoed Reply: label is removed")
        expect(WritingAction.cleaned("Revised:\nHi Priya,"), "Hi Priya,", "an echoed Revised: label is removed")

        // What changed
        func render(_ d: TextDiff) -> String {
            d.segments.map { s in
                switch s.kind {
                case .same: s.text
                case .added: "[+\(s.text)]"
                case .removed: "[-\(s.text)]"
                }
            }.joined()
        }
        let d1 = TextDiff(from: "Hi {Receiver-Name}, I like your work.", to: "Hello {Receiver-Name}, I really like your work.")
        expect(render(d1), "[-Hi][+Hello] {Receiver-Name}, I[+ really] like your work.", "word changes and insertions")
        expect(d1.addedWords, 2, "added word count")
        expect(d1.removedWords, 1, "removed word count")
        let same = TextDiff(from: "No change here.", to: "No change here.")
        expect(same.hasChanges, false, "identical text has no changes")
        expect(same.segments.count, 1, "identical text is one segment")
        let d2 = TextDiff(from: "One two three", to: "One three")
        expect(render(d2), "One [-two ]three", "a deletion")
        let d3 = TextDiff(from: "", to: "Brand new.")
        expect(render(d3), "[+Brand new.]", "from empty")
        let d4 = TextDiff(from: "Line one\nLine two", to: "Line one\n\nLine two")
        expect(d4.addedWords, 0, "extra line break adds no words")
        expect(d4.hasChanges, true, "but is still a change")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
