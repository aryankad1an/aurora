import Foundation

// The word-level comparison writing help shows for review.
//
//   swiftc -parse-as-library Aurora/Models/TextDiff.swift Tests/TextDiffTests.swift -o /tmp/td && /tmp/td

@main
struct TextDiffTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want { print("  ✓ \(label)") } else {
            failures += 1
            print("  ✗ \(label) (line \(line))\n      got:  \(got)\n      want: \(want)")
        }
    }

    static func main() {
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
