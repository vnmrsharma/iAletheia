import Foundation
import SQLite3

final class SearchIndex {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func index(memory: Memory) throws {
        try remove(memoryID: memory.id)
        let sql = """
        INSERT INTO memory_search (
            memory_id, title, content, summary, topics, keywords, source_title
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, memory.id.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, memory.title, -1, transient)
        sqlite3_bind_text(stmt, 3, memory.content, -1, transient)
        sqlite3_bind_text(stmt, 4, memory.summary, -1, transient)
        sqlite3_bind_text(stmt, 5, memory.topics.joined(separator: " "), -1, transient)
        sqlite3_bind_text(stmt, 6, memory.keywords.joined(separator: " "), -1, transient)
        if let sourceTitle = memory.sourceTitle {
            sqlite3_bind_text(stmt, 7, sourceTitle, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to index memory")
        }
    }

    func search(query: String, limit: Int = 10) throws -> [(UUID, Double)] {
        let sanitized = query.replacingOccurrences(of: "\"", with: "")
        let sql = """
        SELECT memory_id, bm25(memory_search) AS score
        FROM memory_search
        WHERE memory_search MATCH ?
        ORDER BY score
        LIMIT ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sanitized, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [(UUID, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let bm25 = sqlite3_column_double(stmt, 1)
            results.append((id, 1.0 / (1.0 + abs(bm25))))
        }
        return results
    }

    func remove(memoryID: UUID) throws {
        try database.exec("DELETE FROM memory_search WHERE memory_id = '\(memoryID.uuidString)';")
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
