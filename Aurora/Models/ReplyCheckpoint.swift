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
/// The search only finds mail that arrived since the last check, so a send the
/// phone didn't know about then — mailed from another device, recorded late,
/// a contact marked invalid and back, a reply taken back as a dead-address
/// notice — could have had its answer before it, and never be found. So the
/// checkpoint also keeps which open threads it covered (`coveredThreadIDs`),
/// and any open thread not among them is read in full. A checkpoint saved
/// without that list (by an older version) can't vouch for anything, and the
/// next check searches the whole window instead, as a first check does.
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
    /// The open threads the last check covered — read, or vouched for by its
    /// search. Nil when no check has recorded them.
    var coveredThreadIDs: Set<String>?

    /// Slack under a checkpoint, so nothing falls between two checks: Gmail's
    /// clock and the phone's differ, and mail can be indexed late.
    static let overlap: TimeInterval = 15 * 60

    init(checkedThrough: Date? = nil, retryThreadIDs: Set<String> = [], noticesCheckedThrough: Date? = nil,
         coveredThreadIDs: Set<String>? = nil) {
        self.checkedThrough = checkedThrough
        self.retryThreadIDs = retryThreadIDs
        self.noticesCheckedThrough = noticesCheckedThrough
        self.coveredThreadIDs = coveredThreadIDs
    }

    /// Reads a checkpoint saved by an older version: its time stands for the
    /// notice checkpoint too, and with no covered threads recorded, the next
    /// check searches the whole window.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedThrough = try c.decodeIfPresent(Date.self, forKey: .checkedThrough)
        retryThreadIDs = try c.decodeIfPresent(Set<String>.self, forKey: .retryThreadIDs) ?? []
        noticesCheckedThrough = try c.decodeIfPresent(Date.self, forKey: .noticesCheckedThrough) ?? checkedThrough
        coveredThreadIDs = try c.decodeIfPresent(Set<String>.self, forKey: .coveredThreadIDs)
    }

    /// Where a check should start searching for new mail in threads: nil to
    /// search the whole window, as an account's first check does — or when
    /// this checkpoint doesn't know which threads it covered.
    func readFrom(fullCheck: Bool) -> Date? {
        guard !fullCheck, let checkedThrough, coveredThreadIDs != nil else { return nil }
        return checkedThrough.addingTimeInterval(-Self.overlap)
    }

    /// Where a check should start searching for failure notices: nil to
    /// search the whole window. `newSends` are when the open sends this
    /// checkpoint didn't cover were sent: a notice for one of those may have
    /// come before the checkpoint, so the search reaches back to it.
    func noticesReadFrom(fullCheck: Bool, newSends: [Date] = []) -> Date? {
        guard !fullCheck, let noticesCheckedThrough, coveredThreadIDs != nil else { return nil }
        var from = noticesCheckedThrough
        if let earliest = newSends.min() { from = min(from, earliest) }
        return from.addingTimeInterval(-Self.overlap)
    }

    /// A check that began at `startedAt` has finished, failing to read the
    /// threads `failedThreadIDs` and `failedNotices` notices. Threads move on
    /// regardless, keeping the failed ones to read again; notices move on only
    /// when none failed. Neither ever moves back. `openThreadIDs` are the
    /// open threads this check covered, read or vouched for by its search.
    mutating func complete(startedAt: Date, openThreadIDs: Set<String>, failedThreadIDs: Set<String>,
                           failedNotices: Int) {
        if startedAt > (checkedThrough ?? .distantPast) {
            checkedThrough = startedAt
            retryThreadIDs = failedThreadIDs
            coveredThreadIDs = openThreadIDs
        }
        if failedNotices == 0, startedAt > (noticesCheckedThrough ?? .distantPast) {
            noticesCheckedThrough = startedAt
        }
    }

    /// Which of the `open` threads a check should read.
    ///
    /// - `incoming`: threads the search found new mail in since the check's
    ///   start point; nil when the search failed or overflowed, and then every
    ///   open thread is read.
    /// - Threads the last check couldn't read (`retry`), ones whose thread was
    ///   only just found (`always`), and — when the search started from a
    ///   checkpoint — any open thread that checkpoint didn't cover.
    func threadsToRead(open: Set<String>, incoming: Set<String>?, searchedFromCheckpoint: Bool,
                       always: Set<String>) -> Set<String> {
        guard let incoming else { return open }
        var wanted = incoming.union(retryThreadIDs).union(always)
        if searchedFromCheckpoint {
            wanted.formUnion(open.subtracting(coveredThreadIDs ?? []))
        }
        return open.intersection(wanted)
    }

    /// A Gmail search term for mail after `date` ("after:1760000000"), or nil
    /// for no limit.
    static func searchTerm(after date: Date?) -> String? {
        date.map { "after:\(Int($0.timeIntervalSince1970))" }
    }
}
