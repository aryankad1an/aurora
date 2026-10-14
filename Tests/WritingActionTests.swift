import Foundation

// The rules around the on-device writing help: what a reply is cleaned of, and
// when a rewrite is refused for having touched a {placeholder}. The model call
// itself needs Apple Intelligence and isn't exercised here.
//
//   swiftc -parse-as-library Aurora/Models/WritingAction.swift \
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
        expect(WritingAction.keepsPlaceholders(original: "No tokens.", result: "No tokens at all."),
               true, "text without placeholders passes")

        expect(WritingAction.cleaned("  Hello there.\n"), "Hello there.", "whitespace trimmed")
        expect(WritingAction.cleaned("\"Hello there.\""), "Hello there.", "wrapping quotes removed")
        expect(WritingAction.cleaned("“Hello there.”"), "Hello there.", "wrapping curly quotes removed")
        expect(WritingAction.cleaned("\"Hi,\" she said, \"bye.\""), "\"Hi,\" she said, \"bye.\"", "inner quotes kept")
        expect(WritingAction.cleaned("```\nHello there.\n```"), "Hello there.", "code fence removed")
        expect(WritingAction.cleaned("```text\nHello there.\n```"), "Hello there.", "labelled code fence removed")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
