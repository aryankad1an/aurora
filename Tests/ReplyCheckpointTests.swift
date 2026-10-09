import Foundation

// Up to when a reply check has read an account's mail, and where the next one
// starts reading. Compiles against the app's own files:
//
//   swiftc -parse-as-library Aurora/Models/ReplyCheckpoint.swift Aurora/Support/JSONFile.swift \
//     Tests/ReplyCheckpointTests.swift -o /tmp/rc && /tmp/rc

@main
struct ReplyCheckpointTests {
    static var failures = 0

    static func expect<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
        if got == want {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label): got [\(got)], want [\(want)] (line \(line))")
        }
    }

    static func main() {
        let noon = Date(timeIntervalSince1970: 1_760_000_000)
        let overlap = ReplyCheckpoint.overlap

        print("Where a check starts reading")
        var checkpoint = ReplyCheckpoint()
        expect(checkpoint.readFrom(fullCheck: false), nil, "an account's first check reads everything")
        checkpoint.complete(startedAt: noon, failedReads: 0)
        expect(checkpoint.checkedThrough, noon, "a clean check moves the checkpoint to when it began")
        expect(checkpoint.readFrom(fullCheck: false), noon.addingTimeInterval(-overlap),
               "the next reads from then, less the overlap")
        expect(checkpoint.readFrom(fullCheck: true), nil, "asked to, it reads everything")

        print("Moving it on")
        var failed = checkpoint
        failed.complete(startedAt: noon.addingTimeInterval(3600), failedReads: 2)
        expect(failed.checkedThrough, noon, "a check with failed reads leaves it where it was")
        var earlier = checkpoint
        earlier.complete(startedAt: noon.addingTimeInterval(-3600), failedReads: 0)
        expect(earlier.checkedThrough, noon, "it never moves back")
        checkpoint.complete(startedAt: noon.addingTimeInterval(3600), failedReads: 0)
        expect(checkpoint.checkedThrough, noon.addingTimeInterval(3600), "a later clean check moves it on")

        print("Searching Gmail")
        expect(ReplyCheckpoint.searchTerm(after: nil), nil, "no checkpoint, no limit")
        expect(ReplyCheckpoint.searchTerm(after: noon), "after:1760000000", "seconds since 1970")

        print("Kept on the phone")
        let folder = FileManager.default.temporaryDirectory.appending(path: "checkpoint-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = JSONFile<ReplyCheckpoint>(name: "reply-checkpoint-a@x.com.json", directory: folder)
        expect(file.load(), nil, "nothing saved yet")
        file.save(checkpoint)
        expect(file.load(), checkpoint, "saved and read back")
        let other = JSONFile<ReplyCheckpoint>(name: "reply-checkpoint-b@x.com.json", directory: folder)
        expect(other.load(), nil, "another account's is its own")

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
