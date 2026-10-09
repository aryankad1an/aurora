import Foundation

// The mail queue against a fake Gmail, interrupted at every stage — a dropped
// connection before and after Gmail took the mail, Gmail failing after taking
// it, rate limits, refusals, Pause, and the app being killed mid-send and
// opened again — checking that nobody is ever mailed twice and nobody is
// skipped. Nothing leaves the machine: "Gmail" is a list in memory, and the
// queue's file goes to a temporary folder.
//
//   swiftc -parse-as-library -default-isolation MainActor \
//     Aurora/Models/MailQueue.swift Aurora/Models/MailBatch.swift \
//     Aurora/Models/MailTemplate.swift Aurora/Models/GmailAuthError.swift \
//     Aurora/Support/JSONFile.swift Tests/MailQueueTests.swift -o /tmp/mq && /tmp/mq

// MARK: - Stand-ins for app types these files reference

extension String {
    /// The app's version lives in Theme.swift, which needs SwiftUI.
    var sanitizedLineSeparators: String { self }
}

struct Contact {
    typealias ID = String
    var greeting = ""
    var position = ""
}

struct Profile {
    var name = "Asha", college = "IIT", company = "", position = "student", resumeLink = "r.pdf"
}

struct SentMail {
    let subject: String
    let body: String
    var gmailMessageID: String?
    var gmailThreadID: String?
}

/// The real one talks to the notification centre, which a command-line
/// program doesn't have.
enum ScheduledMailNotifier {
    static func schedule(_ batch: MailBatch) {}
    static func cancel(_ id: UUID) {}
    static func scheduleResume(_ batch: MailBatch, at date: Date) {}
    static func cancelResume(_ id: UUID) {}
}

// MARK: - A fake Gmail

final class FakeGmail {
    struct Message {
        let id: String
        let to: String
        let subject: String
        let at: Date
    }

    /// Everything Gmail has accepted, in order: what the recipients got.
    private(set) var sentBox: [Message] = []

    /// What each send does, in order; once the script runs out, sends go through.
    enum Step {
        case deliver
        /// Gmail takes the mail, then the connection drops before the answer.
        case acceptThenDrop
        /// The connection drops before Gmail has it.
        case dropBeforeAccept
        /// Gmail takes the mail, then fails with a 5xx.
        case acceptThenUnavailable
        /// Gmail fails with a 5xx and doesn't have it.
        case unavailable
        case rateLimited
        /// A 400: Gmail won't take this mail.
        case refuse
        /// The app is killed while this request is out: it never returns.
        /// After Gmail took the mail, or before.
        case killAfterAccept
        case killBeforeAccept
    }
    var script: [Step] = []
    /// How many Sent searches miss a mail Gmail does have (search lag).
    var searchMisses = 0
    /// Set when a send was "killed": the request that never returns.
    private(set) var killed = false

    func send(to: String, subject: String) async throws -> MailQueue.Delivery? {
        let step = script.isEmpty ? .deliver : script.removeFirst()
        switch step {
        case .deliver:
            return accept(to, subject)
        case .acceptThenDrop:
            _ = accept(to, subject)
            throw URLError(.networkConnectionLost)
        case .dropBeforeAccept:
            throw URLError(.notConnectedToInternet)
        case .acceptThenUnavailable:
            _ = accept(to, subject)
            throw GmailAuthError.unavailable("Backend error", retryAt: .now)
        case .unavailable:
            throw GmailAuthError.unavailable("Backend error", retryAt: .now)
        case .rateLimited:
            throw GmailAuthError.rateLimited("Too many requests", retryAt: .now)
        case .refuse:
            throw GmailAuthError.server("Invalid To header")
        case .killAfterAccept, .killBeforeAccept:
            if case .killAfterAccept = step { _ = accept(to, subject) }
            killed = true
            // Never answers: the app is gone. (A real kill frees this; here the
            // abandoned queue just waits forever, saving nothing more.)
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    func findSent(to: String, since: Date) async throws -> MailQueue.Delivery? {
        guard let found = sentBox.last(where: { $0.to == to && $0.at >= since.addingTimeInterval(-60) }) else {
            return nil
        }
        if searchMisses > 0 {
            searchMisses -= 1
            return nil
        }
        return MailQueue.Delivery(messageID: found.id, threadID: "t-" + found.id)
    }

    func received(_ address: String) -> Int { sentBox.count { $0.to == address } }

    private func accept(_ to: String, _ subject: String) -> MailQueue.Delivery {
        let id = "m\(sentBox.count + 1)"
        sentBox.append(Message(id: id, to: to, subject: subject, at: .now))
        return MailQueue.Delivery(messageID: id, threadID: "t-" + id)
    }
}

// MARK: - Harness

@main
struct MailQueueTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String, line: Int = #line) {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) (line \(line))")
        }
    }

    /// Fast timing: no spacing, no search settle, retries in a blink.
    static var fast: MailQueue.Timing {
        var timing = MailQueue.Timing()
        timing.spacing = .zero
        timing.jitter = 0
        timing.searchSettle = 0
        timing.recheck = 0.05
        timing.retry = [0.05]
        return timing
    }

    final class World {
        let gmail = FakeGmail()
        let folder: URL
        /// What the send history was told, by contact.
        var recorded: [String: Int] = [:]
        var recordWorks = true

        init() {
            folder = FileManager.default.temporaryDirectory.appending(path: "mailqueue-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// A queue as the app opens it: transport wired, then the account loaded.
        func openQueue(timing: MailQueue.Timing = MailQueueTests.fast) -> MailQueue {
            let queue = MailQueue()
            queue.timing = timing
            queue.sender = { [gmail] to, subject, _, _ in try await gmail.send(to: to, subject: subject) }
            queue.verifier = { [gmail] to, since in try await gmail.findSent(to: to, since: since) }
            queue.onRecord = { [unowned self] records in
                guard recordWorks else { return false }
                for id in records.keys { recorded[id, default: 0] += 1 }
                return true
            }
            queue.load(account: "test", directory: folder)
            return queue
        }
    }

    static let people = (1...5).map { "person\($0)@acme.com" }

    static func batch(_ addresses: [String] = people, title: String = "Acme") -> MailBatch {
        let template = UUID()
        return MailBatch(id: UUID(), title: title, createdAt: .now, fromName: "Asha",
                         templates: [template: .init(name: "Intro", subject: "Hello {Receiver-Company}",
                                                     content: "Hi,\nI'm {Sender-Name}.")],
                         mails: addresses.map { address in
                             QueuedMail(id: address, recipient: address, displayName: address, company: "Acme",
                                        context: MailContext(values: [.receiverCompany: "Acme", .senderName: "Asha"]),
                                        templateID: template, override: nil)
                         })
    }

    /// Wait (up to `timeout` seconds) for `condition`.
    @discardableResult
    static func until(_ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            if Date.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    static func finished(_ queue: MailQueue) -> Bool {
        !queue.isRunning && queue.batches.allSatisfy { !$0.hasWork || ($0.isPaused && $0.resumeAt == nil) }
    }

    /// Everyone got exactly one mail.
    static func expectEachOnce(_ world: World, _ label: String, _ addresses: [String] = people) {
        let counts = addresses.map { world.gmail.received($0) }
        expect(counts.allSatisfy { $0 == 1 }, "\(label): each person mailed exactly once \(counts)")
    }

    // MARK: Scenarios

    static func scenario(_ title: String, _ steps: [FakeGmail.Step], at index: Int = 2) async {
        let world = World()
        var script = Array(repeating: FakeGmail.Step.deliver, count: index)
        script += steps
        world.gmail.script = script
        let queue = world.openQueue()
        queue.enqueue(batch())
        let done = await until { finished(queue) && queue.batches.allSatisfy(\.isFinished) }
        expect(done, "\(title): the batch finishes by itself")
        expectEachOnce(world, title)
        expect(queue.batches.allSatisfy { $0.failed == 0 }, "\(title): nothing marked failed")
        await until(2) { world.recorded.count == people.count }
        expect(world.recorded.count == people.count && world.recorded.values.allSatisfy { $0 == 1 },
               "\(title): every send written to the history once")
    }

    static func main() async {
        print("Interrupted sends")
        await scenario("Sent normally", [])
        await scenario("Connection drops after Gmail took the mail", [.acceptThenDrop])
        await scenario("Connection drops before Gmail had it", [.dropBeforeAccept])
        await scenario("Gmail fails (5xx) after taking the mail", [.acceptThenUnavailable])
        await scenario("Gmail fails (5xx) without it", [.unavailable])
        await scenario("Rate limited", [.rateLimited, .rateLimited])
        await scenario("Drops twice in a row", [.acceptThenDrop, .dropBeforeAccept, .acceptThenDrop])

        print("The app killed mid-send, then opened again")
        for kill in [FakeGmail.Step.killAfterAccept, .killBeforeAccept] {
            for lag in [0, 1] {
                let label = (kill == .killAfterAccept ? "Killed after Gmail took it" : "Killed before Gmail had it")
                    + (lag > 0 ? ", Sent search lagging" : "")
                let world = World()
                world.gmail.script = [.deliver, .deliver, kill]
                let first = world.openQueue()
                first.enqueue(batch())
                await until { world.gmail.killed }
                // The app is gone. What's on disk is all the next launch knows.
                world.gmail.searchMisses = lag
                let second = world.openQueue()
                Task { await second.reconcile() }
                let done = await until { finished(second) && second.batches.allSatisfy(\.isFinished) }
                expect(done, "\(label): carries on by itself after relaunch")
                expectEachOnce(world, label)
                _ = first
            }
        }

        print("Refused, paused, retried")
        do {
            let world = World()
            world.gmail.script = [.deliver, .refuse]
            let queue = world.openQueue()
            let sent = batch()
            queue.enqueue(sent)
            await until { finished(queue) }
            expect(queue.batch(sent.id)?.failed == 1, "a 400 marks only that mail failed")
            queue.retryFailed(sent.id)
            await until { finished(queue) && queue.batches.allSatisfy(\.isFinished) }
            expectEachOnce(world, "Retrying a refused mail")
        }
        do {
            let world = World()
            world.gmail.script = [.deliver, .deliver]
            let queue = world.openQueue()
            let sent = batch()
            queue.enqueue(sent)
            await until { (queue.batch(sent.id)?.sent ?? 0) >= 2 }
            queue.pause(sent.id)
            await until { !queue.isRunning }
            expect(queue.batch(sent.id)?.isPaused == true, "Pause stops the run")
            try? await Task.sleep(for: .milliseconds(300))
            expect(queue.batch(sent.id)?.isPaused == true, "…and a paused batch doesn't carry on by itself")
            queue.resume(sent.id)
            await until { finished(queue) && queue.batches.allSatisfy(\.isFinished) }
            expectEachOnce(world, "Paused and resumed")
        }
        do {
            let world = World()
            let queue = world.openQueue()
            var legacy = batch(["unsure@acme.com"])
            legacy.mails[0].status = .failed(reason: MailQueue.unconfirmed)
            queue.enqueue(legacy)
            queue.pause(legacy.id)
            queue.retryFailed(legacy.id)
            try? await Task.sleep(for: .milliseconds(300))
            expect(world.gmail.received("unsure@acme.com") == 0,
                   "a mail whose fate couldn't be checked isn't retried blind")
        }
        do {
            var timing = fast
            timing.maxRetries = 2
            let world = World()
            world.gmail.script = Array(repeating: .dropBeforeAccept, count: 20)
            let queue = world.openQueue(timing: timing)
            let offline = batch(["a@acme.com"])
            queue.enqueue(offline)
            let stopped = await until { finished(queue) && queue.batch(offline.id)?.resumeAt == nil
                && queue.batch(offline.id)?.isPaused == true }
            expect(stopped, "offline for good: stops retrying after maxRetries and waits for Resume")
            expect(world.gmail.received("a@acme.com") == 0, "…having sent nothing")
        }

        print("No one in two batches")
        do {
            let world = World()
            let queue = world.openQueue()
            queue.enqueue(batch(["a@acme.com", "b@acme.com", "a@acme.com"]))
            queue.enqueue(batch(["b@acme.com", "c@acme.com"], title: "Again"))
            await until { finished(queue) && queue.batches.allSatisfy(\.isFinished) }
            expectEachOnce(world, "Overlapping batches", ["a@acme.com", "b@acme.com", "c@acme.com"])
        }
        do {
            let world = World()
            world.recordWorks = false
            let queue = world.openQueue()
            queue.enqueue(batch(["a@acme.com"]))
            await until { finished(queue) && queue.batches.allSatisfy(\.isFinished) }
            expect(queue.waitingContactIDs.contains("a@acme.com"),
                   "a mail sent but not yet in the history still counts as taken")
            queue.enqueue(batch(["a@acme.com"], title: "Again"))
            try? await Task.sleep(for: .milliseconds(300))
            expectEachOnce(world, "Re-queued before the history knew", ["a@acme.com"])
        }

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
