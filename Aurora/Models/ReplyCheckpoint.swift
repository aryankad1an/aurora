import Foundation

/// Up to when an account's mail has been read for replies and bounces, kept on
/// the phone per account (`reply-checkpoint-<account>.json`).
///
/// A reply check reads the threads of open sends — a request each — and two
/// inbox searches for failure notices. Once a check has read what Gmail had
/// when it began, the next only needs what has come since: the threads with
/// inbound mail after that time, and notices after it. Only an account's
/// first check, with no checkpoint to go from, reads everything.
///
/// A few reads failing doesn't send the next check back to the start. The
/// threads that couldn't be read are kept (`retryThreadIDs`) and read again
/// next time whatever else is read, and the checkpoint moves on. Notices are
/// found by searching, not by thread, so their checkpoint only moves on when
/// every notice was read (`noticesCheckedThrough`); one unread is listed
/// again next time, and the rest are skipped as already seen.
nonisolated struct ReplyCheckpoint: Codable, Equatable {
    /// When the last finished check began: threads read up to here.
    var checkedThrough: Date?
    /// Threads the last check couldn't read, to read next time regardless.
    var retryThreadIDs: Set<String> = []
    /// When the last check that read every failure notice it found began.
    var noticesCheckedThrough: Date?

    /// Slack under a checkpoint, so nothing falls between two checks: Gmail's
    /// clock and the phone's differ, and mail can be indexed late.
    static let overlap: TimeInterval = 15 * 60

    init(checkedThrough: Date? = nil, retryThreadIDs: Set<String> = [], noticesCheckedThrough: Date? = nil) {
        self.checkedThrough = checkedThrough
        self.retryThreadIDs = retryThreadIDs
        self.noticesCheckedThrough = noticesCheckedThrough
    }

    /// Reads a checkpoint saved before the retry list and the notice
    /// checkpoint existed: its time stands for both.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedThrough = try c.decodeIfPresent(Date.self, forKey: .checkedThrough)
        retryThreadIDs = try c.decodeIfPresent(Set<String>.self, forKey: .retryThreadIDs) ?? []
        noticesCheckedThrough = try c.decodeIfPresent(Date.self, forKey: .noticesCheckedThrough) ?? checkedThrough
    }

    /// Where a check should start reading threads: nil to read every open one.
    func readFrom(fullCheck: Bool) -> Date? {
        guard !fullCheck, let checkedThrough else { return nil }
        return checkedThrough.addingTimeInterval(-Self.overlap)
    }

    /// Where a check should start searching for failure notices.
    func noticesReadFrom(fullCheck: Bool) -> Date? {
        guard !fullCheck, let noticesCheckedThrough else { return nil }
        return noticesCheckedThrough.addingTimeInterval(-Self.overlap)
    }

    /// A check that began at `startedAt` has finished, failing to read the
    /// threads `failedThreadIDs` and `failedNotices` notices. Threads move on
    /// regardless, keeping the failed ones to read again; notices move on only
    /// when none failed. Neither ever moves back.
    mutating func complete(startedAt: Date, failedThreadIDs: Set<String>, failedNotices: Int) {
        if startedAt > (checkedThrough ?? .distantPast) {
            checkedThrough = startedAt
            retryThreadIDs = failedThreadIDs
        }
        if failedNotices == 0, startedAt > (noticesCheckedThrough ?? .distantPast) {
            noticesCheckedThrough = startedAt
        }
    }

    /// A Gmail search term for mail after `date` ("after:1760000000"), or nil
    /// for no limit.
    static func searchTerm(after date: Date?) -> String? {
        date.map { "after:\(Int($0.timeIntervalSince1970))" }
    }
}
