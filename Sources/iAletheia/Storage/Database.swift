import Foundation
import SQLite3

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case bindFailed
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg), .execFailed(let msg), .prepareFailed(let msg), .stepFailed(let msg):
            return msg
        case .bindFailed:
            return "Failed to bind SQL parameter."
        }
    }
}

final class Database {
    private var db: OpaquePointer?
    let url: URL

    init(path: URL? = nil) throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("iAletheia", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = path ?? dir.appendingPathComponent("memory.db")
        var pointer: OpaquePointer?
        if sqlite3_open(url.path, &pointer) != SQLITE_OK {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(pointer)))
        }
        db = pointer
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA journal_mode = WAL;")
        try DatabaseMigrator.migrate(db: db!)
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let msg = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            sqlite3_free(errorMessage)
            throw DatabaseError.execFailed(msg)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    func clearAll() throws {
        let tables = [
            "chat_messages", "chat_sessions",
            "entity_clusters", "memory_links", "memory_entities", "memory_keywords", "memory_topics",
            "memory_search", "memories", "observations", "episodes", "exclusions"
        ]
        for table in tables {
            try exec("DELETE FROM \(table);")
        }
    }
}

enum DatabaseMigrator {
    static func migrate(db: OpaquePointer) throws {
        let sqls = [
            """
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                summary TEXT NOT NULL,
                source_application TEXT NOT NULL,
                source_title TEXT,
                source_url TEXT,
                first_observed_at REAL NOT NULL,
                last_observed_at REAL NOT NULL,
                occurrence_count INTEGER NOT NULL DEFAULT 1,
                importance REAL NOT NULL,
                confidence REAL NOT NULL,
                sensitivity REAL NOT NULL,
                novelty REAL NOT NULL,
                attention REAL NOT NULL,
                future_utility REAL NOT NULL,
                memory_state TEXT NOT NULL,
                expires_at REAL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_user_corrected INTEGER NOT NULL DEFAULT 0,
                embedding BLOB,
                cloud_processed INTEGER NOT NULL DEFAULT 0,
                admission_reason TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_topics (
                memory_id TEXT NOT NULL,
                topic TEXT NOT NULL,
                PRIMARY KEY (memory_id, topic)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_keywords (
                memory_id TEXT NOT NULL,
                keyword TEXT NOT NULL,
                PRIMARY KEY (memory_id, keyword)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_entities (
                id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                name TEXT NOT NULL,
                normalized_name TEXT NOT NULL,
                context TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_links (
                source_memory_id TEXT NOT NULL,
                target_memory_id TEXT NOT NULL,
                relation_type TEXT NOT NULL,
                relation_strength REAL NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (source_memory_id, target_memory_id, relation_type)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS observations (
                id TEXT PRIMARY KEY,
                captured_at REAL NOT NULL,
                application_name TEXT NOT NULL,
                window_title TEXT,
                source_url TEXT,
                redacted_text TEXT NOT NULL,
                sensitivity_score REAL NOT NULL,
                admission_score REAL NOT NULL,
                decision TEXT NOT NULL,
                retention_expires_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                ended_at REAL,
                dominant_app TEXT NOT NULL,
                topic_hint TEXT,
                observation_ids TEXT NOT NULL,
                memory_ids TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS exclusions (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                value TEXT NOT NULL
            );
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_search USING fts5(
                memory_id UNINDEXED,
                title,
                content,
                summary,
                topics,
                keywords,
                source_title,
                tokenize='porter'
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS entity_clusters (
                id TEXT PRIMARY KEY,
                normalized_name TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                display_name TEXT NOT NULL,
                disambiguator TEXT NOT NULL,
                unified_summary TEXT NOT NULL,
                anchor_memory_id TEXT NOT NULL,
                memory_ids TEXT NOT NULL,
                source_domains TEXT NOT NULL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_entity_clusters_name ON entity_clusters(normalized_name);
            """,
            """
            CREATE TABLE IF NOT EXISTS chat_sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                ended_at REAL,
                message_count INTEGER NOT NULL DEFAULT 0,
                preview TEXT NOT NULL DEFAULT ''
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                citations_json TEXT,
                created_at REAL NOT NULL
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_chat_messages_session ON chat_messages(session_id, created_at);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_chat_sessions_updated ON chat_sessions(updated_at DESC);
            """
        ]
        for sql in sqls {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let msg = errorMessage.map { String(cString: $0) } ?? "Migration failed"
                sqlite3_free(errorMessage)
                throw DatabaseError.execFailed(msg)
            }
        }
        sqlite3_exec(db, "ALTER TABLE memory_entities ADD COLUMN context TEXT;", nil, nil, nil)
    }
}
