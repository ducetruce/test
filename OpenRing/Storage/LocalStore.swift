import Foundation

/// Owns the on-disk copy of `Database`. Writes are atomic, so a crash mid-save can never
/// leave a half-written file behind.
actor LocalStore {
    private let fileURL: URL
    private var cached: Database?

    init(filename: String = "database.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpenRing", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(filename)
    }

    var storageURL: URL { fileURL }

    func load() -> Database {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL) else {
            let fresh = Database()
            cached = fresh
            return fresh
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let database = try? decoder.decode(Database.self, from: data) else {
            // A corrupt file should not brick the app; keep it aside and start clean.
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
            let fresh = Database()
            cached = fresh
            return fresh
        }
        cached = database
        return database
    }

    /// Drop the in-memory copy so the next `load()` re-reads the file. Needed because the
    /// background refresh task writes through its own `LocalStore` instance.
    func invalidateCache() {
        cached = nil
    }

    func save(_ database: Database) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(database)
        try data.write(to: fileURL, options: .atomic)
        // Only advertise the new state through the cache after the atomic write succeeds.
        cached = database
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(load())
    }

    func reset() {
        cached = Database()
        try? FileManager.default.removeItem(at: fileURL)
    }
}
