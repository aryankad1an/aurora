import Foundation
import Observation

/// The line the user writes about each company, which `{Company-Personalised}`
/// fills in when a mail goes to someone there. Kept on this device, per Gmail
/// account, and not in the shared catalog: the catalog is every user's, and a
/// line like "I loved your Atlas launch" is one person's pitch.
@Observable
final class PersonalisedLineStore {
    private(set) var lines: [String: String] = [:]
    private var file: JSONFile<[String: String]>?

    /// Open this account's lines.
    func load(account: String, directory: URL = .documentsDirectory) {
        let file = JSONFile<[String: String]>(name: "personalised-lines-\(account).json", directory: directory)
        self.file = file
        lines = file.load() ?? [:]
    }

    /// What a company's lines are filed under: its name without case, accents or
    /// stray spaces, so "Stripe" and " stripe " are one company.
    static func key(_ company: String) -> String {
        company.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The line for `company`, or "" when none was written.
    func line(for company: String) -> String {
        lines[Self.key(company)] ?? ""
    }

    /// Save `line` for `company`; an empty line removes it. When a company is
    /// renamed, `previousName` moves its line along instead of orphaning it.
    func set(_ line: String, for company: String, previousName: String? = nil) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let previousName, Self.key(previousName) != Self.key(company) {
            lines.removeValue(forKey: Self.key(previousName))
        }
        if text.isEmpty {
            lines.removeValue(forKey: Self.key(company))
        } else {
            lines[Self.key(company)] = text
        }
        file?.save(lines)
    }
}
