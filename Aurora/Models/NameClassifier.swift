import Foundation

/// Whether an email address names a person, and the given name to greet them by.
///
/// A mailbox is read as one of the few patterns a work address is built from:
/// a given name alone (`rahul`), given name and surname (`neha.mathur`,
/// `nehamathur`), initials and surname (`akushwah`, `pm.singh`), given name and
/// initial (`rahulk`), initial and given name (`r.saravanan`), a surname alone,
/// an English word, or none of those. Each pattern is a small generative model
/// with a prior. A word's likelihood in a slot comes from how common it is as a
/// given name, a surname or an English word, and letter trigrams spell out the
/// names the lists don't have and anything that isn't a name at all. Separators
/// must fall between slots; without them every split is tried.
///
/// Each reading's posterior is credited to the given name it would greet, and a
/// name is used only when its share reaches the model's threshold. A given name
/// has to be known to be greeted: one the model has never seen is never
/// guessed, but it still counts against the readings that would misgreet —
/// `singh.gurpreet` is not "Hi Singh," just because Gurpreet is unlisted.
///
/// Names are known from public lists and, with `learn(people:)`, from the
/// catalog's own name fields: "Arijit Sen" on one contact lets `arijit@` on
/// another be greeted.
///
/// The model is `Resources/NameModel.txt`, built by `scripts/names/build_model.py`
/// from public name and word lists. `scripts/names/name_model.py` is the
/// reference implementation; its tests check this port against it case by case.
final class NameClassifier {
    /// The model shipped in the app, or nil if it's missing from the bundle.
    static let shared: NameClassifier? = (Bundle.main.url(forResource: "NameModel", withExtension: "txt")
        ?? Bundle.main.url(forResource: "NameModel", withExtension: "txt", subdirectory: "Resources"))
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { NameClassifier(modelBytes: [UInt8]($0)) }

    struct Greeting {
        /// The given name to greet by, capitalized, or nil when no name is sure enough.
        let name: String?
        /// The share of readings behind the best known name, 0...1.
        let confidence: Double
    }

    private enum Slot {
        /// `initials` is one or two letters; `initial` exactly one, and
        /// `gluedInitial` one with no separator before it — never a vowel,
        /// which there ends a name: `suneeta` is not Suneet + A.
        case given, surname, initials, initial, gluedInitial, word

        var index: Int {
            switch self {
            case .given: 0
            case .surname: 1
            case .initials: 2
            case .initial: 3
            case .gluedInitial: 4
            case .word: 5
            }
        }
    }

    private struct Pattern {
        let slots: [Slot]
        let prior: Double
        /// Chance each boundary is written with no separator.
        let glue: Double
        /// The slot whose word is greeted.
        let greets: Int?
    }

    private enum Trigrams: String { case other = "trigram_other", given = "trigram_given", surname = "trigram_surname" }

    /// What the catalog has taught: counts by name, and their total.
    private struct Learned {
        var counts: [String: Int] = [:]
        var total = 0
    }

    /// The model file. The name and word sections stay in it, sorted, and are
    /// searched in place: building dictionaries of 200,000 names on first use
    /// would cost far more than the few lookups a mailbox needs.
    private let bytes: [UInt8]
    /// Where each line of the given-name, surname and word sections starts.
    private var given: [Int32] = []
    private var surnames: [Int32] = []
    private var words: [Int32] = []
    private var patterns: [Pattern] = []
    private var otherPrior = 0.0
    /// Per table, -ln P(next | two before), indexed ((a * 27) + b) * 27 + c with
    /// a, b in 0 (start) or 1...26 (a-z) and c in 0...25 (a-z) or 26 (end).
    private var trigrams: [Trigrams: [Double]] = [:]
    private var constants: [String: Double] = [:]
    private var scale = 4.0
    private(set) var threshold = 0.9
    private var learnedGiven = Learned()
    private var learnedSurnames = Learned()
    /// Mailboxes already read. A batch reads each recipient's greeting more
    /// than once, and the compose and contact screens on every redraw.
    private var memo: [[String]: Greeting] = [:]

    private static let required = ["scale", "threshold", "given_oov", "surname_oov", "initial1", "initial2",
                                   "catalog_prior", "catalog_max", "catalog_min_count", "learn_order",
                                   "learn_unlisted", "compound_suffix"]

    convenience init?(modelText: String) {
        self.init(modelBytes: Array(modelText.utf8))
    }

    /// Parse a model file. Nil if it's malformed.
    init?(modelBytes: [UInt8]) {
        bytes = modelBytes
        var section = ""
        var priors: [(String, Double)] = []
        var glue: [String: Double] = [:]
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            defer { start = end + 1 }
            guard end > start, bytes[start] != UInt8(ascii: "#") else { continue }
            if bytes[start] == UInt8(ascii: "@") {
                section = String(decoding: bytes[(start + 1)..<end], as: UTF8.self)
                continue
            }
            switch section {
            case "given": given.append(Int32(start))
            case "surname": surnames.append(Int32(start))
            case "words": words.append(Int32(start))
            case "priors", "glue", "constants":
                let line = String(decoding: bytes[start..<end], as: UTF8.self).split(separator: " ")
                guard line.count == 2, let value = Double(line[1]) else { return nil }
                let key = String(line[0])
                switch section {
                case "priors": priors.append((key, value))
                case "glue": glue[key] = value
                default: constants[key] = value
                }
            default:
                guard let table = Trigrams(rawValue: section), end - start >= 3 + 27 else { return nil }
                if trigrams[table] == nil { trigrams[table] = Array(repeating: 0, count: 27 * 27 * 27) }
                let row = [bytes[start], bytes[start + 1]].map { $0 == UInt8(ascii: "^") ? 0 : Int($0) - 96 }
                for c in 0..<27 {
                    trigrams[table]![(row[0] * 27 + row[1]) * 27 + c] = Double(Int(bytes[start + 3 + c]) - 33) * 0.2
                }
            }
        }
        guard Self.required.allSatisfy({ constants[$0] != nil }), trigrams.count == 3,
              !given.isEmpty, !surnames.isEmpty, !words.isEmpty else { return nil }
        scale = constants["scale"]!
        threshold = constants["threshold"]!
        for (name, prior) in priors {
            if name == "O" {
                otherPrior = prior
                continue
            }
            let slots = name.map { letter -> Slot in
                switch letter {
                case "G": .given
                case "S": .surname
                case "I": .initials
                case "i": .initial
                default: .word
                }
            }
            patterns.append(Pattern(slots: slots, prior: prior, glue: glue[name] ?? 0,
                                    greets: slots.firstIndex(of: .given)))
        }
    }

    /// Who `parts` — a mailbox's lowercase a-z runs, in order — greets.
    func greeting(parts: [String]) -> Greeting {
        if let known = memo[parts] { return known }
        if memo.count > 4096 { memo.removeAll(keepingCapacity: true) }
        let result = read(parts)
        memo[parts] = result
        return result
    }

    // MARK: - Learning from the catalog

    /// Learn given names and surnames from the catalog's own name fields,
    /// replacing anything learned before.
    ///
    /// `people` are name fields as lowercase a-z words in the order written,
    /// with notes, honorifics and rows naming a role already left out. Only the
    /// first and last word are read. A field teaches only when it's clear which
    /// way round it is — written given name first unless the listed words say
    /// otherwise, one reading nine times likelier than the other — and one half
    /// is listed in its role: "Arijit Sen" teaches Arijit, "Singh Gurpreet"
    /// teaches Gurpreet. A common English word teaches nothing unless the lists
    /// know it as a name, and a name only the catalog knows is greeted once it
    /// has been taught more than once.
    func learn(people: [[String]]) {
        var taughtGiven = Learned(), taughtSurnames = Learned()
        let order = constants["learn_order"]!
        for words in people {
            guard words.count >= 2, let a = words.first, let b = words.last, a != b,
                  min(a.utf8.count, b.utf8.count) >= 3 else { continue }
            let forward = order * publicP(given, a) * publicP(surnames, b)
            let backward = (1 - order) * publicP(surnames, a) * publicP(given, b)
            let (first, last): (String, String)
            if forward >= 9 * backward {
                (first, last) = (a, b)
            } else if backward >= 9 * forward {
                (first, last) = (b, a)
            } else {
                continue
            }
            guard cost(given, first) != nil || cost(surnames, last) != nil else { continue }
            if teaches(first, given) { taughtGiven.counts[first, default: 0] += 1; taughtGiven.total += 1 }
            if teaches(last, surnames) { taughtSurnames.counts[last, default: 0] += 1; taughtSurnames.total += 1 }
        }
        learnedGiven = taughtGiven
        learnedSurnames = taughtSurnames
        memo.removeAll()
    }

    /// A word's listed probability, or a role-neutral floor if it isn't listed.
    private func publicP(_ section: [Int32], _ word: String) -> Double {
        cost(section, word).map { exp(-Double($0) / scale) } ?? constants["learn_unlisted"]!
    }

    private func teaches(_ word: String, _ section: [Int32]) -> Bool {
        cost(section, word) != nil || cost(words, word) == nil
    }

    private func knowsGiven(_ word: String) -> Bool {
        cost(given, word) != nil || Double(learnedGiven.counts[word] ?? 0) >= constants["catalog_min_count"]!
    }

    // MARK: - Reading

    private func read(_ parts: [String]) -> Greeting {
        let readings = self.readings(parts)
        let candidates = readings.compactMap { $0.name }.filter(knowsGiven)
        var closest = 0.0
        for name in candidates.sorted(by: { $0.count > $1.count }) {
            let support = readings.reduce(0.0) { total, reading in
                guard let full = reading.name, calls(full, name) else { return total }
                return total + reading.share
            }
            closest = max(closest, support)
            if support >= threshold {
                return Greeting(name: name.prefix(1).uppercased() + name.dropFirst(), confidence: support)
            }
        }
        return Greeting(name: nil, confidence: closest)
    }

    /// Every way to read the mailbox, credited to the given name each would
    /// greet (nil for none), as shares of the whole. Most likely first.
    private func readings(_ parts: [String]) -> [(name: String?, share: Double)] {
        let text = Array(parts.joined().utf8)
        let n = text.count
        guard n > 0 else { return [] }
        var cuts: [Int] = []
        for part in parts.dropLast() { cuts.append((cuts.last ?? 0) + part.utf8.count) }

        // Each stretch of letters is looked up once per kind of slot, however
        // many patterns and splits put it there. Stretches are keyed by their
        // bounds: start * (n + 1) + end.
        var seen: [[Double]] = Array(repeating: Array(repeating: -1, count: (n + 1) * (n + 1)), count: 6)
        func stretch(_ key: Int) -> ArraySlice<UInt8> { text[(key / (n + 1))..<(key % (n + 1))] }
        func slot(_ kind: Slot, _ key: Int) -> Double {
            if seen[kind.index][key] < 0 { seen[kind.index][key] = likelihood(of: stretch(key), as: kind) }
            return seen[kind.index][key]
        }

        // Shares by the stretch greeted (-1 for no one), in the order first met.
        var scores: [Int: Double] = [:]
        var order: [Int] = []
        func add(_ key: Int, _ p: Double) {
            if scores[key] == nil { order.append(key) }
            scores[key, default: 0] += p
        }

        for pattern in patterns {
            let k = pattern.slots.count
            guard k - 1 >= cuts.count, n >= k else { continue }
            // Boundaries between slots, walked in lexicographic order. A split
            // is allowed when every separator is one of them.
            var bounds = Array(1..<k)
            while true {
                if cuts.allSatisfy(bounds.contains) {
                    var p = pattern.prior
                    for b in bounds { p *= cuts.contains(b) ? 1 - pattern.glue : pattern.glue }
                    var greeted = -1
                    for i in 0..<k where p > 0 {
                        let start = i == 0 ? 0 : bounds[i - 1]
                        let key = start * (n + 1) + (i == k - 1 ? n : bounds[i])
                        var kind = pattern.slots[i]
                        if kind == .initial, !cuts.contains(start) { kind = .gluedInitial }
                        p *= slot(kind, key)
                        if i == pattern.greets { greeted = key }
                    }
                    if p > 0 { add(greeted, p) }
                }
                // Advance the rightmost boundary that can still move.
                guard let i = (0..<(k - 1)).last(where: { bounds[$0] < n - (k - 1 - $0) }) else { break }
                bounds[i] += 1
                for j in (i + 1)..<(k - 1) { bounds[j] = bounds[j - 1] + 1 }
            }
        }
        let other = parts.reduce(otherPrior) { $0 * trigram(.other, Array($1.utf8)[...]) }
        if other > 0 { add(-1, other) }

        // The same name can be read off two stretches ("rahul.rahul").
        var shares: [String?: Double] = [:]
        var names: [String?] = []
        for key in order {
            let name: String? = key < 0 ? nil : String(decoding: stretch(key), as: UTF8.self)
            if shares[name] == nil { names.append(name) }
            shares[name, default: 0] += scores[key]!
        }
        let total = names.reduce(0.0) { $0 + shares[$1]! }
        guard total > 0 else { return [(nil, 1)] }
        return names.map { ($0, shares[$0]! / total) }.sorted { $0.share > $1.share }
    }

    /// Whether someone whose given name reads as `full` goes by `name`: the same
    /// name, or a known one that is `name` with a common surname fused on
    /// (Rakesh + kumar, Lakshmi + devi, Srinivasa + rao). Anything else fused
    /// doesn't shorten: Nagarjuna isn't "Nag", Lakshmanan isn't "Laksh".
    private func calls(_ full: String, _ name: String) -> Bool {
        if full == name { return true }
        guard full.hasPrefix(name), knowsGiven(full) else { return false }
        let rest = String(full.dropFirst(name.count))
        guard rest.utf8.count >= 3, let c = cost(surnames, rest) else { return false }
        return exp(-Double(c) / scale) >= constants["compound_suffix"]!
    }

    // MARK: - Slot likelihoods

    private func likelihood(of word: ArraySlice<UInt8>, as slot: Slot) -> Double {
        switch slot {
        case .given: listed(word, in: given, learned: learnedGiven, oov: constants["given_oov"]!, spelt: .given)
        case .surname: listed(word, in: surnames, learned: learnedSurnames, oov: constants["surname_oov"]!, spelt: .surname)
        case .initials: word.count == 1 ? constants["initial1"]! : word.count == 2 ? constants["initial2"]! : 0
        case .initial: word.count == 1 ? constants["initial1"]! : 0
        case .gluedInitial: word.count == 1 && !Array("aeiou".utf8).contains(word.first!) ? constants["initial1"]! : 0
        case .word: cost(words, word) != nil ? 1 / Double(words.count) : 0
        }
    }

    private func listed(_ word: ArraySlice<UInt8>, in section: [Int32], learned: Learned,
                        oov: Double, spelt: Trigrams) -> Double {
        guard word.count >= 2 else { return 0 }
        var p = cost(section, word).map { exp(-Double($0) / scale) } ?? 0
        // Names the catalog taught, blended in by how much it has taught: the
        // catalog is the population being greeted, but a small one.
        if learned.total > 0 {
            let n = Double(learned.total)
            let share = min(constants["catalog_max"]!, n / (n + constants["catalog_prior"]!))
            let count = Double(learned.counts[String(decoding: word, as: UTF8.self)] ?? 0)
            p = (1 - share) * p + share * count / n
        }
        return (1 - oov) * p + oov * trigram(spelt, word)
    }

    private func trigram(_ table: Trigrams, _ word: ArraySlice<UInt8>) -> Double {
        guard let costs = trigrams[table] else { return 0 }
        var nats = 0.0, a = 0, b = 0
        for byte in word {
            let c = Int(byte) - 97
            guard (0..<26).contains(c) else { return 0 }
            nats += costs[(a * 27 + b) * 27 + c]
            (a, b) = (b, c + 1)
        }
        nats += costs[(a * 27 + b) * 27 + 26]
        return exp(-nats)
    }

    // MARK: - The sorted sections

    private func cost(_ section: [Int32], _ word: String) -> Int? {
        cost(section, Array(word.utf8)[...])
    }

    /// The number after `word` on its line in `section` (0 for the word list),
    /// or nil if the section doesn't have it.
    private func cost(_ section: [Int32], _ word: ArraySlice<UInt8>) -> Int? {
        var low = 0, high = section.count
        while low < high {
            let mid = (low + high) / 2
            let order = compare(Int(section[mid]), word)
            if order == 0 { return number(after: Int(section[mid]) + word.count) }
            if order < 0 { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    /// The line at `start`'s name against `word`: negative if it sorts first.
    private func compare(_ start: Int, _ word: ArraySlice<UInt8>) -> Int {
        var i = start, j = word.startIndex
        while true {
            let lineEnded = i >= bytes.count || bytes[i] == UInt8(ascii: " ") || bytes[i] == UInt8(ascii: "\n")
            let wordEnded = j == word.endIndex
            if lineEnded || wordEnded { return lineEnded ? (wordEnded ? 0 : -1) : 1 }
            if bytes[i] != word[j] { return bytes[i] < word[j] ? -1 : 1 }
            i += 1
            j += 1
        }
    }

    private func number(after index: Int) -> Int {
        var i = index + 1, value = 0
        while i < bytes.count, (48...57).contains(bytes[i]) {
            value = value * 10 + Int(bytes[i]) - 48
            i += 1
        }
        return value
    }
}
