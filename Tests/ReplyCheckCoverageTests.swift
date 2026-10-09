import Foundation

// That reading only new mail never misses a reply. Runs the checkpoint's own
// logic (`ReplyCheckpoint`: where to search from, which threads to read, how
// it moves on) against a model mailbox in which replies arrive at any time,
// sends become known late (another device, a contact marked invalid and back),
// reads and searches fail, the app is reinstalled, the account is signed out
// and back in, another account is used in between, and a checkpoint saved by
// an older version is found. After every history, one more clean check must
// have found every reply. Nothing touches the network.
//
//   swiftc -parse-as-library Aurora/Models/ReplyCheckpoint.swift \
//     Tests/ReplyCheckCoverageTests.swift -o /tmp/cc && /tmp/cc

/// A small deterministic random source, so a failure can be replayed.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// The phone's side of one account: its checkpoint (gone on reinstall) and
/// the replies it has recorded (kept in the database, so they survive).
struct Phone {
    var checkpoint = ReplyCheckpoint()
    var reads = 0
}

struct Send {
    let thread: String
    let sentAt: Double
    /// When this phone first knows about it.
    let knownAt: Double
    /// Marked invalid (and so not checked) between these times.
    var invalid: ClosedRange<Double>?
}

struct Mailbox {
    var sends: [Send] = []
    /// Replies by thread: when they arrived.
    var replies: [String: [Double]] = [:]
    /// Replies the database has recorded, by thread.
    var recorded: Set<String> = []

    static let window: Double = 120 * 86_400

    func open(at now: Double) -> [Send] {
        sends.filter { send in
            send.knownAt <= now && !recorded.contains(send.thread) && send.sentAt > now - Self.window
                && !(send.invalid?.contains(now) ?? false)
        }
    }

    /// The search: threads with mail from someone else in (after, now].
    func incoming(after: Double, now: Double) -> Set<String> {
        Set(replies.filter { _, times in times.contains { $0 > after && $0 <= now } }.keys)
    }

    /// Reading a thread finds a reply if one came after the send.
    func hasReply(_ send: Send, now: Double) -> Bool {
        replies[send.thread]?.contains { $0 > send.sentAt && $0 <= now } ?? false
    }

    /// Every reply that has arrived to a send the phone knows of.
    func answered(by now: Double) -> Set<String> {
        Set(sends.filter { $0.knownAt <= now && hasReply($0, now: now) }.map(\.thread))
    }
}

/// One check, as `ReplySync.run` does it.
func check(_ phone: inout Phone, _ mailbox: inout Mailbox, now: Double,
           searchFails: Bool = false, readFails: (String) -> Bool = { _ in false }) {
    let started = Date(timeIntervalSince1970: now)
    let open = mailbox.open(at: now)
    let openIDs = Set(open.map(\.thread))
    let since = phone.checkpoint.readFrom(fullCheck: false)
    let from = since?.timeIntervalSince1970 ?? now - Mailbox.window
    let incoming = searchFails ? nil : mailbox.incoming(after: from, now: now)
    let wanted = phone.checkpoint.threadsToRead(open: openIDs, incoming: incoming,
                                                searchedFromCheckpoint: since != nil, always: [])
    var failed = Set<String>()
    for send in open where wanted.contains(send.thread) {
        phone.reads += 1
        if readFails(send.thread) { failed.insert(send.thread); continue }
        if mailbox.hasReply(send, now: now) { mailbox.recorded.insert(send.thread) }
    }
    phone.checkpoint.complete(startedAt: started, openThreadIDs: openIDs, failedThreadIDs: failed,
                              failedNotices: 0)
}

@main
struct ReplyCheckCoverageTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String, line: Int = #line) {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) (line \(line))")
        }
    }

    static let day: Double = 86_400
    static let start: Double = 1_760_000_000

    static func main() {
        print("Named cases")
        // A send from another device: its reply came before this phone's
        // last check, and the phone only learns of the send afterwards.
        do {
            var mailbox = Mailbox()
            var phone = Phone()
            mailbox.sends = [Send(thread: "a", sentAt: start, knownAt: start)]
            check(&phone, &mailbox, now: start + day)
            mailbox.sends.append(Send(thread: "b", sentAt: start + day, knownAt: start + 3 * day))
            mailbox.replies["b"] = [start + 1.5 * day]
            check(&phone, &mailbox, now: start + 2 * day)
            check(&phone, &mailbox, now: start + 3 * day)
            expect(mailbox.recorded.contains("b"), "a send learnt of late has its earlier reply found")
        }
        // A contact marked invalid while their reply came, then valid again.
        do {
            var mailbox = Mailbox()
            var phone = Phone()
            mailbox.sends = [Send(thread: "a", sentAt: start, knownAt: start, invalid: start + day...start + 3 * day)]
            check(&phone, &mailbox, now: start + 0.5 * day)
            mailbox.replies["a"] = [start + 2 * day]
            check(&phone, &mailbox, now: start + 2.5 * day)
            check(&phone, &mailbox, now: start + 4 * day)
            expect(mailbox.recorded.contains("a"), "a contact made valid again has the reply that came meanwhile")
        }
        // Reinstalled: no checkpoint, and the window is searched.
        do {
            var mailbox = Mailbox()
            var phone = Phone()
            mailbox.sends = (0..<50).map { Send(thread: "t\($0)", sentAt: start, knownAt: start) }
            mailbox.replies["t7"] = [start + day]
            check(&phone, &mailbox, now: start + 2 * day)
            phone = Phone()  // reinstalled: the checkpoint is gone, the database isn't
            mailbox.replies["t9"] = [start + 2.5 * day]
            check(&phone, &mailbox, now: start + 3 * day)
            expect(mailbox.recorded == ["t7", "t9"], "after a reinstall, nothing is missed")
            expect(phone.reads == 1, "…and only the thread with new mail is read (\(phone.reads) of 49 open)")
        }
        // A checkpoint saved by an older version, without its covered threads.
        do {
            var mailbox = Mailbox()
            mailbox.sends = [Send(thread: "late", sentAt: start, knownAt: start + 2 * day)]
            mailbox.replies["late"] = [start + day]
            var phone = Phone()
            phone.checkpoint = ReplyCheckpoint(checkedThrough: Date(timeIntervalSince1970: start + 1.5 * day))
            expect(phone.checkpoint.readFrom(fullCheck: false) == nil, "an old checkpoint searches the whole window")
            check(&phone, &mailbox, now: start + 3 * day)
            expect(mailbox.recorded.contains("late"), "…and misses nothing it couldn't vouch for")
        }
        // Signed out, another account used, signed back in: each account's
        // checkpoint is its own, and one used against the wrong account's
        // threads vouches for none of them.
        do {
            var mailboxA = Mailbox()
            var mailboxB = Mailbox()
            mailboxA.sends = [Send(thread: "a1", sentAt: start, knownAt: start)]
            mailboxB.sends = [Send(thread: "b1", sentAt: start, knownAt: start)]
            var phoneA = Phone()
            check(&phoneA, &mailboxA, now: start + day)
            mailboxB.replies["b1"] = [start + 0.5 * day]
            // B checked with A's checkpoint left in memory, by mistake.
            var confused = phoneA
            check(&confused, &mailboxB, now: start + 2 * day)
            expect(mailboxB.recorded.contains("b1"), "another account's checkpoint can't hide this account's reply")
            mailboxA.replies["a1"] = [start + 1.5 * day]
            check(&phoneA, &mailboxA, now: start + 3 * day)
            expect(mailboxA.recorded.contains("a1"), "signed back in, the reply that came meanwhile is found")
        }
        // The search fails: every open thread is read.
        do {
            var mailbox = Mailbox()
            var phone = Phone()
            mailbox.sends = (0..<5).map { Send(thread: "t\($0)", sentAt: start, knownAt: start) }
            check(&phone, &mailbox, now: start + day)
            mailbox.replies["t3"] = [start + 1.5 * day]
            let before = phone.reads
            check(&phone, &mailbox, now: start + 2 * day, searchFails: true)
            expect(mailbox.recorded.contains("t3") && phone.reads - before == 5, "a failed search reads every open thread")
        }
        // A read fails: that thread is read next time, and the rest move on.
        do {
            var mailbox = Mailbox()
            var phone = Phone()
            mailbox.sends = [Send(thread: "a", sentAt: start, knownAt: start)]
            mailbox.replies["a"] = [start + 0.5 * day]
            check(&phone, &mailbox, now: start + day, readFails: { _ in true })
            expect(!mailbox.recorded.contains("a"), "a thread that couldn't be read isn't marked")
            check(&phone, &mailbox, now: start + 30 * day)
            expect(mailbox.recorded.contains("a"), "…and is read on the next check, however much later")
        }

        print("Random histories")
        var generator = SeededRandom(state: 42)
        var histories = 0, missed = 0, reads = 0, openSeen = 0
        for _ in 0..<2_000 {
            histories += 1
            var mailbox = Mailbox()
            var phone = Phone()
            var now = start
            for index in 0..<Int.random(in: 5...40, using: &generator) {
                let sentAt = now - Double.random(in: 0...(5 * day), using: &generator)
                let knownLate = Bool.random(using: &generator) && Int.random(in: 0..<4, using: &generator) == 0
                let knownAt = knownLate ? sentAt + Double.random(in: 0...(10 * day), using: &generator) : sentAt
                var send = Send(thread: "t\(index)", sentAt: sentAt, knownAt: knownAt)
                if Int.random(in: 0..<8, using: &generator) == 0 {
                    let from = sentAt + Double.random(in: 0...(3 * day), using: &generator)
                    send.invalid = from...(from + Double.random(in: 0...(5 * day), using: &generator))
                }
                mailbox.sends.append(send)
                if Int.random(in: 0..<3, using: &generator) == 0 {
                    mailbox.replies[send.thread] = [sentAt + Double.random(in: 60...(15 * day), using: &generator)]
                }
                // Some replies come in more than once (a colleague, then them).
                if Int.random(in: 0..<10, using: &generator) == 0 {
                    mailbox.replies[send.thread, default: []].append(sentAt + Double.random(in: 60...(20 * day), using: &generator))
                }
            }
            for _ in 0..<Int.random(in: 3...25, using: &generator) {
                now += Double.random(in: 60...(3 * day), using: &generator)
                switch Int.random(in: 0..<20, using: &generator) {
                case 0: phone = Phone()  // reinstalled
                case 1: phone.checkpoint.coveredThreadIDs = nil  // an older version's checkpoint
                default: break
                }
                openSeen += mailbox.open(at: now).count
                let before = phone.reads
                check(&phone, &mailbox, now: now,
                      searchFails: Int.random(in: 0..<15, using: &generator) == 0,
                      readFails: { _ in Int.random(in: 0..<12, using: &generator) == 0 })
                reads += phone.reads - before
            }
            // One clean check at the end must have everything.
            now += 60
            check(&phone, &mailbox, now: now)
            let answered = mailbox.answered(by: now).filter { thread in
                mailbox.sends.first { $0.thread == thread }.map { $0.sentAt > now - Mailbox.window && !($0.invalid?.contains(now) ?? false) } ?? false
            }
            if !answered.isSubset(of: mailbox.recorded) { missed += 1 }
        }
        expect(missed == 0, "\(histories) random histories (late sends, invalid spells, reinstalls, old checkpoints, failed reads and searches): no reply missed")
        let share = Double(reads) / Double(max(openSeen, 1))
        expect(share < 0.5, "…while reading \(Int((share * 100).rounded()))% of the open threads a read-everything check would")

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
