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
        expect(checkpoint.readFrom(fullCheck: false), nil, "an account's first check reads every thread")
        expect(checkpoint.noticesReadFrom(fullCheck: false), nil, "…and searches every notice")
        checkpoint.complete(startedAt: noon, openThreadIDs: ["t1", "t2"], failedThreadIDs: [], failedNotices: 0)
        expect(checkpoint.checkedThrough, noon, "a clean check moves the checkpoint to when it began")
        expect(checkpoint.readFrom(fullCheck: false), noon.addingTimeInterval(-overlap),
               "the next reads from then, less the overlap")
        expect(checkpoint.coveredThreadIDs, ["t1", "t2"], "…and knows which threads it covered")
        expect(checkpoint.noticesReadFrom(fullCheck: false), noon.addingTimeInterval(-overlap), "notices too")
        expect(checkpoint.readFrom(fullCheck: true), nil, "asked to, it reads everything")

        print("A few reads failing doesn't send the next check back to the start")
        let hour = noon.addingTimeInterval(3600)
        var failed = checkpoint
        failed.complete(startedAt: hour, openThreadIDs: ["t1", "t2"], failedThreadIDs: ["t1", "t2"], failedNotices: 0)
        expect(failed.checkedThrough, hour, "threads move on even when some couldn't be read")
        expect(failed.retryThreadIDs, ["t1", "t2"], "…keeping those to read again next time")
        failed.complete(startedAt: hour.addingTimeInterval(3600), openThreadIDs: ["t1", "t2"], failedThreadIDs: [], failedNotices: 0)
        expect(failed.retryThreadIDs, [], "read cleanly, they're dropped")
        var noticeFailed = checkpoint
        noticeFailed.complete(startedAt: hour, openThreadIDs: ["t1", "t2"], failedThreadIDs: [], failedNotices: 3)
        expect(noticeFailed.checkedThrough, hour, "an unread notice doesn't hold threads back")
        expect(noticeFailed.noticesCheckedThrough, noon, "…but notices are searched from where they were")
        var earlier = checkpoint
        earlier.complete(startedAt: noon.addingTimeInterval(-3600), openThreadIDs: ["t1", "t2"], failedThreadIDs: ["t9"], failedNotices: 0)
        expect(earlier.checkedThrough, noon, "it never moves back")
        expect(earlier.retryThreadIDs, [], "…nor does an older check's retry list replace a newer one's")

        print("Notices for sends new to this phone")
        var notices = ReplyCheckpoint()
        notices.complete(startedAt: hour, openThreadIDs: ["t1"], failedThreadIDs: [], failedNotices: 0)
        expect(notices.noticesReadFrom(fullCheck: false), hour.addingTimeInterval(-overlap), "normally, from the last check")
        let yesterday = hour.addingTimeInterval(-86_400)
        expect(notices.noticesReadFrom(fullCheck: false, newSends: [yesterday]), yesterday.addingTimeInterval(-overlap),
               "a send new to this phone pulls the search back to when it was sent")
        expect(notices.noticesReadFrom(fullCheck: false, newSends: [hour.addingTimeInterval(60)]),
               hour.addingTimeInterval(-overlap), "…but one sent since doesn't push it forward")

        print("A checkpoint saved before retries existed")
        let old = #"{"checkedThrough":781692800}"#.data(using: .utf8)!
        let upgraded = try? JSONDecoder().decode(ReplyCheckpoint.self, from: old)
        expect(upgraded?.checkedThrough, Date(timeIntervalSinceReferenceDate: 781692800), "keeps its time")
        expect(upgraded?.noticesCheckedThrough, Date(timeIntervalSinceReferenceDate: 781692800), "…for notices too")
        expect(upgraded?.retryThreadIDs, [], "…with nothing to retry")
        expect(upgraded?.readFrom(fullCheck: false), nil, "…but searches the whole window, not knowing what it covered")

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
        let first = ReplyCheckRecord(startedAt: noon, readFrom: nil)
        log.begin(first)
        var second = ReplyCheckRecord(startedAt: hour, readFrom: noon)
        second.plan = ["Linking sent mail to threads", "Checking threads for replies"]
        log.begin(second)
        expect(log.records.map(\.id), [second.id, first.id], "while a check runs, the one before it stays")
        log.update(second.id) {
            $0.steps.append(.init(title: "Checking threads for replies", summary: "Read 3 threads"))
            $0.result = .incomplete
            $0.finishedAt = $0.startedAt.addingTimeInterval(12)
        }
        log.keepOnly(second.id)
        expect(log.records.map(\.id), [second.id], "once it finishes, it replaces the one before")
        expect(log.records.first?.steps.count, 1, "a step is recorded")
        expect(log.records.first?.duration, 12, "…and how long it took")
        for _ in 0..<5 { log.begin(ReplyCheckRecord(startedAt: hour, readFrom: nil)) }
        expect(log.records.count, ReplyCheckLog.limit, "never more than \(ReplyCheckLog.limit) kept")
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
