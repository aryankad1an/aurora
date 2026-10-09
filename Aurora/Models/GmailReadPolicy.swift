import Foundation

/// How the app reads Gmail without tripping its per-user rate limit, and what
/// it does when Gmail turns a read away anyway.
///
/// Gmail allows each user about 250 quota units a second, and a thread read
/// costs 10. A full reply check reads every open thread — hundreds — and read
/// five at a time as fast as they'd go, about half came back refused and were
/// counted as "couldn't be read". So reads are spaced (`spacing`: 20 a second,
/// 200 units for thread reads), and one refused for the rate or a moment's
/// outage is tried again (`retryDelay`) before it counts as failed.
/// `Tests/GmailReadPolicyTests.swift` checks both against a model of the limit.
nonisolated enum GmailReadPolicy {
    /// Reads start no closer together than this.
    static let spacing: TimeInterval = 0.05
    /// How many times a turned-away read is tried again.
    static let retries = 4

    /// How long to wait before trying a read again after Gmail answered
    /// `status`, or nil to give up: only a rate limit (429, or a 403 whose
    /// reason is one) or a 5xx is worth another try, and only `retries` times.
    /// The wait is what Gmail said (`said`, seconds from now) when it said,
    /// else 1, 2, 4, 8 s — between half a second and half a minute either way.
    static func retryDelay(status: Int, isRateLimit: Bool, said: TimeInterval?, attempt: Int) -> TimeInterval? {
        let retryable = status == 429 || (500...599).contains(status) || (status == 403 && isRateLimit)
        guard retryable, attempt < retries else { return nil }
        return min(max(said ?? pow(2, Double(attempt)), 0.5), 30)
    }
}

/// Hands out start times for reads, in call order, `GmailReadPolicy.spacing`
/// apart — so reads started together queue up rather than burst. A wait Gmail
/// asks for holds back every read after it, since the limit is the account's.
nonisolated struct GmailReadPacer {
    private(set) var nextAt = Date.distantPast

    /// When a read asked for `now` may start; reserves that slot.
    mutating func reserve(now: Date) -> Date {
        let start = max(now, nextAt)
        nextAt = start.addingTimeInterval(GmailReadPolicy.spacing)
        return start
    }

    /// Hold every later read until at least `date`.
    mutating func hold(until date: Date) {
        nextAt = max(nextAt, date)
    }
}
