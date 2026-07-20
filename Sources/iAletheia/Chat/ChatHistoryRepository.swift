import Foundation
import SQLite3

final class ChatHistoryRepository {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    func createSession(_ session: ChatSession) throws {
        let sql = """
        INSERT INTO chat_sessions (id, title, started_at, updated_at, ended_at, message_count, preview)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, session.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
        if let ended = session.endedAt {
            sqlite3_bind_double(stmt, 5, ended.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(session.messageCount))
        sqlite3_bind_text(stmt, 7, session.preview, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to create chat session")
        }
    }

    func updateSession(_ session: ChatSession) throws {
        let sql = """
        UPDATE chat_sessions
        SET title = ?, updated_at = ?, ended_at = ?, message_count = ?, preview = ?
        WHERE id = ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, session.updatedAt.timeIntervalSince1970)
        if let ended = session.endedAt {
            sqlite3_bind_double(stmt, 3, ended.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int(stmt, 4, Int32(session.messageCount))
        sqlite3_bind_text(stmt, 5, session.preview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, session.id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to update chat session")
        }
    }

    func appendMessage(_ message: StoredChatMessage) throws {
        let sql = """
        INSERT INTO chat_messages (id, session_id, role, text, citations_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, message.sessionID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, message.role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, message.text, -1, SQLITE_TRANSIENT)
        if let citations = message.citationsJSON {
            sqlite3_bind_text(stmt, 5, citations, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, message.timestamp.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to save chat message")
        }
    }

    func fetchSessions(limit: Int = 100) throws -> [ChatSession] {
        let sql = """
        SELECT id, title, started_at, updated_at, ended_at, message_count, preview
        FROM chat_sessions
        ORDER BY updated_at DESC
        LIMIT ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var sessions: [ChatSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let ended: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            sessions.append(ChatSession(
                id: id,
                title: String(cString: sqlite3_column_text(stmt, 1)),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                endedAt: ended,
                messageCount: Int(sqlite3_column_int(stmt, 5)),
                preview: String(cString: sqlite3_column_text(stmt, 6))
            ))
        }
        return sessions
    }

    func fetchMessages(sessionID: UUID) throws -> [StoredChatMessage] {
        let sql = """
        SELECT id, session_id, role, text, citations_json, created_at
        FROM chat_messages
        WHERE session_id = ?
        ORDER BY created_at ASC;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, SQLITE_TRANSIENT)
        var messages: [StoredChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let sessionText = sqlite3_column_text(stmt, 1),
                  let session = UUID(uuidString: String(cString: sessionText)) else { continue }
            let role = StoredChatMessage.Role(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .user
            let citations = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 4))
            messages.append(StoredChatMessage(
                id: id,
                sessionID: session,
                role: role,
                text: String(cString: sqlite3_column_text(stmt, 3)),
                citationsJSON: citations,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            ))
        }
        return messages
    }

    func deleteSession(id: UUID) throws {
        try database.exec("DELETE FROM chat_messages WHERE session_id = '\(id.uuidString)';")
        try database.exec("DELETE FROM chat_sessions WHERE id = '\(id.uuidString)';")
    }

    func endSession(id: UUID) throws {
        let now = Date().timeIntervalSince1970
        try database.exec("UPDATE chat_sessions SET ended_at = \(now), updated_at = \(now) WHERE id = '\(id.uuidString)';")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
