import Foundation

// How reads are paced and retried to stay under Gmail's per-user rate limit,
// checked against a model of that limit. Nothing touches the network.
//
//   swiftc -parse-as-library Aurora/Models/GmailReadPolicy.swift \
//     Tests/GmailReadPolicyTests.swift -o /tmp/gr && /tmp/gr

@main
struct GmailReadPolicyTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String, line: Int = #line) {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) (line \(line))")
        }
    }

    /// Gmail's limit as modelled here: 250 quota units in any second, a thread
    /// read costing 10. Returns how many of the reads starting at `starts`
    /// (seconds) were refused. Refused reads use no quota.
    static func refused(_ starts: [Double], unitsPerRead: Int = 10, perSecond: Int = 250) -> Int {
        var accepted: [Double] = []
        var refusals = 0
        for start in starts.sorted() {
            let used = accepted.filter { $0 > start - 1 }.count * unitsPerRead
            if used + unitsPerRead > perSecond { refusals += 1 } else { accepted.append(start) }
        }
        return refusals
    }

    static func main() {
        print("The limit, modelled")
        // The old way: five reads at a time, each taking 100 ms — 50 a second.
        let threads = 731
        let unpaced = (0..<threads).map { Double($0 / 5) * 0.1 }
        let before = refused(unpaced)
        expect(before > threads / 3, "unpaced, a full check of \(threads) threads is refused \(before) times")

        print("Paced")
        var pacer = GmailReadPacer()
        let origin = Date(timeIntervalSince1970: 0)
        // All asked for at once, as five concurrent workers would.
        let paced = (0..<threads).map { _ in pacer.reserve(now: origin).timeIntervalSince(origin) }
        expect(refused(paced) == 0, "paced, none of the \(threads) is refused")
        expect(zip(paced, paced.dropFirst()).allSatisfy { abs(($1 - $0) - GmailReadPolicy.spacing) < 1e-6 },
               "reads start \(Int(GmailReadPolicy.spacing * 1000)) ms apart")
        expect(paced.last! < 40, "…and the whole check still takes under 40 s (\(Int(paced.last!)) s)")
        var later = GmailReadPacer()
        _ = later.reserve(now: origin)
        let afterGap = later.reserve(now: origin.addingTimeInterval(5))
        expect(afterGap == origin.addingTimeInterval(5), "a read asked for after a quiet spell starts at once")
        later.hold(until: origin.addingTimeInterval(20))
        expect(later.reserve(now: origin.addingTimeInterval(6)) == origin.addingTimeInterval(20),
               "a wait Gmail asks for holds back every later read")

        print("Retries")
        expect(GmailReadPolicy.retryDelay(status: 429, isRateLimit: false, said: nil, attempt: 0) == 1, "429: wait 1 s")
        expect(GmailReadPolicy.retryDelay(status: 429, isRateLimit: false, said: nil, attempt: 2) == 4, "…doubling: 4 s on the third")
        expect(GmailReadPolicy.retryDelay(status: 429, isRateLimit: false, said: nil, attempt: 4) == nil, "…and giving up after 4")
        expect(GmailReadPolicy.retryDelay(status: 429, isRateLimit: false, said: 12, attempt: 0) == 12, "the time Gmail gives is used")
        expect(GmailReadPolicy.retryDelay(status: 429, isRateLimit: false, said: 600, attempt: 0) == 30, "…up to 30 s")
        expect(GmailReadPolicy.retryDelay(status: 403, isRateLimit: true, said: nil, attempt: 0) != nil, "a 403 that's a rate limit is retried")
        expect(GmailReadPolicy.retryDelay(status: 503, isRateLimit: false, said: nil, attempt: 0) != nil, "a 5xx is retried")
        for status in [400, 401, 403, 404] {
            expect(GmailReadPolicy.retryDelay(status: status, isRateLimit: false, said: nil, attempt: 0) == nil,
                   "\(status) isn't retried")
        }

        if failures > 0 {
            print("\n\(failures) failed")
            exit(1)
        }
        print("\nAll passed")
    }
}
