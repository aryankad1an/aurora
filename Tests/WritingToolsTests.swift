import Foundation

// The logic around the system's Writing Tools: noticing that it closed having
// changed the text, flagging damage to {placeholders}, and the word-level
// comparison shown for review. The panel itself is Apple's and isn't exercised.
//
//   swiftc -parse-as-library Aurora/Models/WritingToolsTracker.swift Aurora/Models/TextDiff.swift \
//     Tests/WritingToolsTests.swift -o /tmp/wt && /tmp/wt

@main
struct WritingToolsTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() {
        // The tracker
        var t = WritingToolsTracker(text: "hello")
        expect(t.observe(isActive: false, text: "hello"), nil, "nothing happens while idle")
        expect(t.observe(isActive: false, text: "hello world"), nil, "ordinary typing is not a change")
        expect(t.observe(isActive: true, text: "hello world"), nil, "opening the panel is not a change")
        expect(t.observe(isActive: true, text: "Hello, world!"), nil, "nothing is reported while it is open")
        let change = t.observe(isActive: false, text: "Hello, world!")
        expect(change?.before, "hello world", "the change's before is what the user had when it opened")
        expect(change?.after, "Hello, world!", "the change's after is what it left")
        expect(t.observe(isActive: false, text: "Hello, world!"), nil, "a change is reported once")

        var same = WritingToolsTracker(text: "a")
        _ = same.observe(isActive: true, text: "a")
        expect(same.observe(isActive: false, text: "a"), nil, "closing with nothing changed (reverted) reports nothing")

        var typing = WritingToolsTracker(text: "a")
        _ = same.observe(isActive: false, text: "a")
        _ = typing.observe(isActive: false, text: "ab")
        _ = typing.observe(isActive: true, text: "ab")
        expect(typing.observe(isActive: false, text: "abc")?.before, "ab", "typing before opening is the baseline")
        _ = typing.observe(isActive: false, text: "abc")
        expect(typing.observe(isActive: false, text: "abcd"), nil, "typing after closing is not a change")

        // Placeholder damage
        let intact = PlaceholderDamage(before: "Hi {Receiver-Name}, {Resume-Link}", after: "Hello {Resume-Link} {Receiver-Name}")
        expect(intact.isEmpty, true, "reordered placeholders are fine")
        let dropped = PlaceholderDamage(before: "Hi {Receiver-Name}, {Resume-Link}", after: "Hello {Receiver-Name}")
        expect(dropped.removed, ["{Resume-Link}"], "a dropped placeholder is reported")
        let renamed = PlaceholderDamage(before: "Hi {Receiver-Name}", after: "Hi {Receiver Name}")
        expect(renamed.removed, ["{Receiver-Name}"], "a respelt placeholder is removed...")
        expect(renamed.added, ["{Receiver Name}"], "...and an invented one added")
        expect(PlaceholderDamage(before: "{A} {A}", after: "{A}").removed, ["{A}"], "one of two copies lost is reported")
        expect(PlaceholderDamage(before: "No tokens.", after: "No tokens at all.").isEmpty, true, "plain text is untouched")

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
        let identical = TextDiff(from: "No change here.", to: "No change here.")
        expect(identical.hasChanges, false, "identical text has no changes")
        expect(render(TextDiff(from: "One two three", to: "One three")), "One [-two ]three", "a deletion")
        expect(render(TextDiff(from: "", to: "Brand new.")), "[+Brand new.]", "from empty")
        let spacing = TextDiff(from: "Line one\nLine two", to: "Line one\n\nLine two")
        expect(spacing.addedWords, 0, "an extra line break adds no words")
        expect(spacing.hasChanges, true, "but is still a change")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
