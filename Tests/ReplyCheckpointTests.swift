import Foundation

// Up to when a reply check has read an account's mail, where the next one
// starts reading, and the timeline of checks kept for Activity. Compiles
// against the app's own files:
//
//   swiftc -parse-as-library Aurora/Models/ReplyCheckpoint.swift Aurora/Models/ReplyCheckLog.swift \
//     Aurora/Models/GmailAuthError.swift Aurora/Support/JSONFile.swift \
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

        print("The timeline of checks")
        var log = ReplyCheckLog()
        var ids: [UUID] = []
        for minute in 0..<(ReplyCheckLog.limit + 5) {
            let record = ReplyCheckRecord(startedAt: noon.addingTimeInterval(Double(minute) * 60), readFrom: nil)
            ids.append(record.id)
            log.begin(record)
        }
        expect(log.records.count, ReplyCheckLog.limit, "keeps the latest \(ReplyCheckLog.limit)")
        expect(log.records.first?.id, ids.last, "newest first")
        log.update(ids.last!) {
            $0.steps.append(.init(title: "Checking for replies", summary: "Read 3 threads"))
            $0.result = .incomplete
            $0.finishedAt = $0.startedAt.addingTimeInterval(12)
        }
        expect(log.records.first?.steps.count, 1, "a step is recorded")
        expect(log.records.first?.duration, 12, "…and how long it took")
        log.update(ids.first!) { $0.result = .complete }
        expect(log.records.contains { $0.id == ids.first! }, false, "an update to one no longer kept is dropped")
        let logFile = JSONFile<ReplyCheckLog>(name: "reply-checks-a@x.com.json", directory: folder)
        logFile.save(log)
        expect(logFile.load(), log, "saved and read back")

        print("Why reads failed, said briefly")
        expect(ReplyCheckLog.reason(for: GmailAuthError.server("User-rate limit exceeded")),
               "Gmail's rate limit, even after waiting", "a rate limit Gmail kept up")
        expect(ReplyCheckLog.reason(for: URLError(.networkConnectionLost)), "Connection dropped", "a dropped connection")
        expect(ReplyCheckLog.reason(for: URLError(.notConnectedToInternet)), "Offline", "offline")
        expect(ReplyCheckLog.issues(["Offline": 1, "Connection dropped": 3]),
               ["3 couldn't be read: Connection dropped", "1 couldn't be read: Offline"], "most common first")

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
