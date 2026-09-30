import Foundation

/// Loads and saves a Codable value as JSON in the app's Documents folder.
/// Shared by all the stores so the persistence code lives in one place.
struct JSONFile<Value: Codable> {
    let name: String

    private var url: URL {
        URL.documentsDirectory.appending(path: name)
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
            }
            return nil
        }
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
