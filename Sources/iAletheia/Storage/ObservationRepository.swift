import Foundation
import SQLite3

final class ObservationRepository {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(record: ProcessedObservationRecord, retentionDays: Int = 14) throws {
        let expires = Date().addingTimeInterval(Double(retentionDays) * 86400)
        let sql = """
        INSERT INTO observations (
            id, captured_at, application_name, window_title, source_url,
            redacted_text, sensitivity_score, admission_score, decision, retention_expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, transient)
        sqlite3_bind_double(stmt, 2, record.capturedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, record.applicationName, -1, transient)
        if let title = record.windowTitle {
            sqlite3_bind_text(stmt, 4, title, -1, transient)
        } else { sqlite3_bind_null(stmt, 4) }
        if let url = record.sourceURL {
            sqlite3_bind_text(stmt, 5, url, -1, transient)
        } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_text(stmt, 6, record.redactedText, -1, transient)
        sqlite3_bind_double(stmt, 7, record.sensitivityScore)
        sqlite3_bind_double(stmt, 8, record.admissionScore)
        sqlite3_bind_text(stmt, 9, record.decision, -1, transient)
        sqlite3_bind_double(stmt, 10, expires.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to save observation")
        }
    }

    func fetchRecent(limit: Int = 50) throws -> [ProcessedObservationRecord] {
        let sql = """
        SELECT id, captured_at, application_name, window_title, source_url,
               redacted_text, sensitivity_score, admission_score, decision
        FROM observations ORDER BY captured_at DESC LIMIT ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var records: [ProcessedObservationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            records.append(ProcessedObservationRecord(
                id: id,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                applicationName: String(cString: sqlite3_column_text(stmt, 2)),
                windowTitle: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                sourceURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                redactedText: String(cString: sqlite3_column_text(stmt, 5)),
                sensitivityScore: sqlite3_column_double(stmt, 6),
                admissionScore: sqlite3_column_double(stmt, 7),
                decision: String(cString: sqlite3_column_text(stmt, 8))
            ))
        }
        return records
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
