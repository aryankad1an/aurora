import Foundation

// The rules around the on-device writing help: what a reply is cleaned of, and
// when a rewrite is refused for having touched a {placeholder}. The model call
// itself needs Apple Intelligence and isn't exercised here.
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
