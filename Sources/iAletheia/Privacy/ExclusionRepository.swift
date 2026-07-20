import Foundation
import SQLite3

final class ExclusionRepository {
    private let database: Database

    init(database: Database) {
        self.database = database
        seedDefaultsIfNeeded()
        removeObsoleteExclusions()
    }

    func isExcluded(bundleID: String, url: String?) -> Bool {
        let defaults = defaultExclusions()
        if defaults.contains(bundleID) { return true }
        if let url, url.contains("private") || url.starts(with: "chrome://") { return true }
        return (try? fetchAll().contains(where: { $0.value == bundleID || (url != nil && $0.value == url) })) ?? false
    }

    func fetchAll() throws -> [(id: UUID, kind: String, value: String)] {
        let sql = "SELECT id, kind, value FROM exclusions;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [(UUID, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            rows.append((id, String(cString: sqlite3_column_text(stmt, 1)), String(cString: sqlite3_column_text(stmt, 2))))
        }
        return rows
    }

    func add(kind: String, value: String) throws {
        let sql = "INSERT OR IGNORE INTO exclusions (id, kind, value) VALUES (?, ?, ?);"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, kind, -1, transient)
        sqlite3_bind_text(stmt, 3, value, -1, transient)
        _ = sqlite3_step(stmt)
    }

    private func seedDefaultsIfNeeded() {
        for bundle in defaultExclusions() {
            try? add(kind: "app", value: bundle)
        }
    }

    private func defaultExclusions() -> [String] {
        [
            "com.1password.1password",
            "com.apple.keychainaccess",
            Bundle.main.bundleIdentifier ?? "com.ialetheia.app"
        ]
    }

    /// Drop legacy defaults that blocked IDE/terminal capture in older builds.
    private func removeObsoleteExclusions() {
        let obsolete = [
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.apple.Terminal",
            "com.apple.SafariTechnologyPreview"
        ]
        for bundle in obsolete {
            try? exec("DELETE FROM exclusions WHERE kind = 'app' AND value = ?;", value: bundle)
        }
    }

    private func exec(_ sql: String, value: String) throws {
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, transient)
        _ = sqlite3_step(stmt)
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
