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

    /// Refile a company's line under its new name, after a rename. A line already
    /// written for the new name is kept rather than overwritten.
    func move(from oldName: String, to newName: String) {
        let old = Self.key(oldName), new = Self.key(newName)
        guard old != new, let line = lines[old] else { return }
        lines.removeValue(forKey: old)
        if lines[new] == nil { lines[new] = line }
        file?.save(lines)
    }

    /// Save `line` for `company`; an empty line removes it.
    func set(_ line: String, for company: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            lines.removeValue(forKey: Self.key(company))
        } else {
            lines[Self.key(company)] = text
        }
        file?.save(lines)
    }
}
