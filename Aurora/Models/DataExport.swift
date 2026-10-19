import Foundation

/// Everything Settings → Export Data writes to the device: the shared catalog
/// and this account's own rows, exactly as the database holds them — every
/// column, including ones this version of the app doesn't use.
struct DataExport {
    let account: String
    let exportedAt: Date
    let companies: [[String: Any]]
    let contacts: [[String: Any]]
    let sources: [[String: Any]]
    let sends: [[String: Any]]
    let templates: [[String: Any]]
    let profile: [[String: Any]]
    let tracked: [[String: Any]]

    /// The tables in the order they're written, with their file names.
    var tables: [(name: String, rows: [[String: Any]])] {
        [("companies", companies), ("contacts", contactsWithCompany), ("company_sources", sources),
         ("mail_sends", sends), ("templates", templates), ("profile", profile),
         ("tracked_companies", tracked)]
    }

    /// The figures the export screen shows before anything is saved.
    var summary: [(label: String, count: Int)] {
        [("Companies", companies.count), ("Contacts", contacts.count), ("Hiring sources", sources.count),
         ("Sent mails", sends.count), ("Templates", templates.count), ("Companies on Home", tracked.count)]
    }

    /// Contacts with their company's name beside its id, so the sheet reads on
    /// its own without a lookup.
    private var contactsWithCompany: [[String: Any]] {
        var names: [String: String] = [:]
        for company in companies {
            if let id = company["id"] as? String, let name = company["name"] as? String { names[id] = name }
        }
        return contacts.map { contact in
            var row = contact
            if let id = contact["company_id"] as? String { row["company_name"] = names[id] ?? NSNull() }
            return row
        }
    }

    // MARK: - JSON

    /// One file: every table under its own key, plus when and for whom.
    func json() throws -> Data {
        var root: [String: Any] = [
            "exported_at": ISO8601DateFormatter().string(from: exportedAt),
            "account": account,
            "format": "Aurora export, version 1",
            "counts": Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0.rows.count) })
        ]
        for table in tables { root[table.name] = table.rows }
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - CSV

    /// One CSV per table, keyed by file name ("companies.csv"). UTF-8 with a
    /// byte-order mark, so a spreadsheet app reads "₹" and names in any script
    /// correctly.
    func csvFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        for table in tables {
            files["\(table.name).csv"] = Data(("\u{FEFF}" + CSV.table(table.rows)).utf8)
        }
        return files
    }

    /// A name for the saved file or folder: "Aurora export 2026-10-14".
    var baseFilename: String {
        // The phone's own date: in UTC an export just after midnight in India
        // was named for the day before.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Aurora export \(f.string(from: exportedAt))"
    }
}

enum ExportError: LocalizedError {
    case signedOut

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in with Gmail to export your data."
        }
    }
}

/// Rows of JSON objects as comma-separated values.
nonisolated enum CSV {
    /// The leading columns, when a table has them; every other column follows
    /// alphabetically, so the same table always comes out in the same order.
    private static let leading = ["id", "name", "company_id", "company_name", "email"]

    static func table(_ rows: [[String: Any]]) -> String {
        let keys = Set(rows.flatMap(\.keys))
        let columns = leading.filter(keys.contains) + keys.subtracting(leading).sorted()
        guard !columns.isEmpty else { return "" }
        var lines = [columns.map(escape).joined(separator: ",")]
        for row in rows {
            lines.append(columns.map { escape(cell(row[$0])) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One value as text: lists joined with " | " (as the ledger's CSVs do),
    /// nested objects as JSON, null as empty.
    static func cell(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let text as String: return text
        case let number as NSNumber:
            // JSON's true and false arrive as numbers too; say them as words.
            if String(cString: number.objCType) == "c" { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let list as [Any]: return list.map { cell($0) }.joined(separator: " | ")
        case let object as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        case let other?: return "\(other)"
        }
    }

    /// Quoted when it holds a comma, a quote or a line break; quotes doubled.
    static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
