import Foundation

/// Loads and saves a Codable value as JSON in the app's Documents folder.
/// Shared by all the stores so the persistence code lives in one place.
struct JSONFile<Value: Codable> {
    let name: String
    /// Where it's kept: the app's Documents, or a folder of a test's own.
    var directory: URL = .documentsDirectory

    private var url: URL {
        directory.appending(path: name)
    }

    func load() -> Value? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            // A missing file is expected on first launch; only real read/decode
            // failures are worth surfacing.
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                print("JSONFile: failed to load \(name): \(error)")
                setAside()
            }
            return nil
        }
    }

    /// Move a file that exists but can't be read out of the way, rather than
    /// let the next save write over it. Its owner starts empty either way; this
    /// is the difference between a queue of mail lost and one kept to recover.
    private func setAside() {
        let stamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let aside = directory.appending(path: "\(name).unreadable-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            // Atomic write so an interrupted save can't corrupt existing data.
            try data.write(to: url, options: .atomic)
        } catch {
            print("JSONFile: failed to save \(name): \(error)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
