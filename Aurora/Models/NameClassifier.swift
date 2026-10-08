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
/// has to be in the lists to be greeted: one the model has never seen is never
/// guessed, but it still counts against the readings that would misgreet —
/// `singh.gurpreet` is not "Hi Singh," just because Gurpreet is unlisted.
///
/// The model is `Resources/NameModel.txt`, built by `scripts/names/build_model.py`
/// from public name and word lists. `scripts/names/name_model.py` is the
/// reference implementation; its tests check this port against it case by case.
final class NameClassifier {
    /// The model shipped in the app, or nil if it's missing from the bundle.
    /// Read on first use, about a tenth of a second.
    static let shared: NameClassifier? = (Bundle.main.url(forResource: "NameModel", withExtension: "txt")
        ?? Bundle.main.url(forResource: "NameModel", withExtension: "txt", subdirectory: "Resources"))
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .flatMap { NameClassifier(modelText: $0) }

    struct Greeting {
        /// The given name to greet by, capitalized, or nil when no name is sure enough.
        let name: String?
        /// The share of readings behind the best listed name, 0...1.
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

    private var patterns: [Pattern] = []
    private var otherPrior = 0.0
    private var given: [String: Int] = [:]
    private var surnames: [String: Int] = [:]
    private var words: Set<String> = []
    /// Per table, -ln P(next | two before), indexed ((a * 27) + b) * 27 + c with
    /// a, b in 0 (start) or 1...26 (a-z) and c in 0...25 (a-z) or 26 (end).
    private var trigrams: [Trigrams: [Double]] = [:]
    private var scale = 4.0
    private(set) var threshold = 0.9
    private var givenOOV = 0.0, surnameOOV = 0.0, initial1 = 0.0, initial2 = 0.0
    /// Mailboxes already read. A batch reads each recipient's greeting more
    /// than once, and the compose and contact screens on every redraw.
    private var memo: [[String]: Greeting] = [:]

    /// Parse a model file. Nil if it's malformed.
    init?(modelText: String) {
        var section = ""
        var priors: [(String, Double)] = []
        var glue: [String: Double] = [:]
        var constants: [String: Double] = [:]
        given.reserveCapacity(32_768)
        surnames.reserveCapacity(32_768)
        words.reserveCapacity(12_288)
        for line in modelText.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("@") {
                section = String(line.dropFirst())
                continue
            }
            if section == "words" {
                words.insert(String(line))
                continue
            }
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = String(line[..<space]), value = line[line.index(after: space)...]
            switch section {
            case "priors": priors.append((key, Double(value) ?? 0))
            case "glue": glue[key] = Double(value)
            case "constants": constants[key] = Double(value)
            case "given": given[key] = Int(value)
            case "surname": surnames[key] = Int(value)
            default:
                guard let table = Trigrams(rawValue: section), key.utf8.count == 2 else { return nil }
                if trigrams[table] == nil { trigrams[table] = Array(repeating: 0, count: 27 * 27 * 27) }
                let row = key.utf8.map { $0 == UInt8(ascii: "^") ? 0 : Int($0) - 96 }
                for (c, byte) in value.utf8.enumerated() where c < 27 {
                    trigrams[table]![(row[0] * 27 + row[1]) * 27 + c] = Double(Int(byte) - 33) * 0.2
                }
            }
        }
        guard let scale = constants["scale"], let threshold = constants["threshold"],
              let givenOOV = constants["given_oov"], let surnameOOV = constants["surname_oov"],
              let initial1 = constants["initial1"], let initial2 = constants["initial2"],
              trigrams.count == 3, !words.isEmpty else { return nil }
        (self.scale, self.threshold, self.givenOOV, self.surnameOOV) = (scale, threshold, givenOOV, surnameOOV)
        (self.initial1, self.initial2) = (initial1, initial2)
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

    private func read(_ parts: [String]) -> Greeting {
        let readings = self.readings(parts)
        let candidates = readings.compactMap { $0.name }.filter { given[$0] != nil }
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

    // MARK: - Readings

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
        var spelled: [String?] = Array(repeating: nil, count: (n + 1) * (n + 1))
        var seen: [[Double]] = Array(repeating: Array(repeating: -1, count: (n + 1) * (n + 1)), count: 6)
        func word(_ key: Int) -> String {
            if let w = spelled[key] { return w }
            let w = String(decoding: text[(key / (n + 1))..<(key % (n + 1))], as: UTF8.self)
            spelled[key] = w
            return w
        }
        func slot(_ kind: Slot, _ key: Int) -> Double {
            if seen[kind.index][key] < 0 { seen[kind.index][key] = likelihood(of: word(key), as: kind) }
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
        let other = parts.reduce(otherPrior) { $0 * trigram(.other, $1) }
        if other > 0 { add(-1, other) }

        // The same name can be read off two stretches ("rahul.rahul").
        var shares: [String?: Double] = [:]
        var names: [String?] = []
        for key in order {
            let name: String? = key < 0 ? nil : word(key)
            if shares[name] == nil { names.append(name) }
            shares[name, default: 0] += scores[key]!
        }
        let total = names.reduce(0.0) { $0 + shares[$1]! }
        guard total > 0 else { return [(nil, 1)] }
        return names.map { ($0, shares[$0]! / total) }.sorted { $0.share > $1.share }
    }

    /// Whether someone whose given name reads as `full` goes by `name`: the same
    /// name, or a listed one that is `name` with a surname fused on (Rakesh +
    /// kumar, Lakshmi + devi). Two given names fused don't shorten: Nagarjuna
    /// isn't "Nag".
    private func calls(_ full: String, _ name: String) -> Bool {
        if full == name { return true }
        guard full.hasPrefix(name), given[full] != nil else { return false }
        let rest = String(full.dropFirst(name.count))
        return rest.utf8.count >= 3 && surnames[rest] != nil
    }

    // MARK: - Slot likelihoods

    private func likelihood(of word: String, as slot: Slot) -> Double {
        switch slot {
        case .given: listed(word, in: given, oov: givenOOV, spelt: .given)
        case .surname: listed(word, in: surnames, oov: surnameOOV, spelt: .surname)
        case .initials: word.utf8.count == 1 ? initial1 : word.utf8.count == 2 ? initial2 : 0
        case .initial: word.utf8.count == 1 ? initial1 : 0
        case .gluedInitial: word.utf8.count == 1 && !"aeiou".contains(word) ? initial1 : 0
        case .word: words.contains(word) ? 1 / Double(words.count) : 0
        }
    }

    private func listed(_ word: String, in table: [String: Int], oov: Double, spelt: Trigrams) -> Double {
        guard word.utf8.count >= 2 else { return 0 }
        let p = table[word].map { exp(-Double($0) / scale) } ?? 0
        return (1 - oov) * p + oov * trigram(spelt, word)
    }

    private func trigram(_ table: Trigrams, _ word: String) -> Double {
        guard let costs = trigrams[table] else { return 0 }
        var nats = 0.0, a = 0, b = 0
        for byte in word.utf8 {
            let c = Int(byte) - 97
            guard (0..<26).contains(c) else { return 0 }
            nats += costs[(a * 27 + b) * 27 + c]
            (a, b) = (b, c + 1)
        }
        nats += costs[(a * 27 + b) * 27 + 26]
        return exp(-nats)
    }
}
