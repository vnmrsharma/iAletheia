import Foundation
import SQLite3

final class EpisodeService {
    private let database: Database
    private var activeEpisodeID: UUID?

    init(database: Database) {
        self.database = database
    }

    func attach(observationID: UUID, memoryID: UUID?, app: String, topicHint: String?) throws {
        if activeEpisodeID == nil {
            activeEpisodeID = try createEpisode(app: app, topicHint: topicHint, observationID: observationID, memoryID: memoryID)
            return
        }
        guard let episodeID = activeEpisodeID else { return }
        var episode = try fetch(id: episodeID) ?? Episode(
            id: episodeID, startedAt: Date(), endedAt: nil, dominantApp: app,
            topicHint: topicHint, observationIDs: [], memoryIDs: []
        )
        if !episode.observationIDs.contains(observationID) {
            episode.observationIDs.append(observationID)
        }
        if let memoryID, !episode.memoryIDs.contains(memoryID) {
            episode.memoryIDs.append(memoryID)
        }
        episode.endedAt = Date()
        try save(episode)
    }

    func fetchRecent(limit: Int = 30) throws -> [Episode] {
        let sql = "SELECT id, started_at, ended_at, dominant_app, topic_hint, observation_ids, memory_ids FROM episodes ORDER BY started_at DESC LIMIT ?;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var episodes: [Episode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let ended = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let app = String(cString: sqlite3_column_text(stmt, 3))
            let topic = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let obs = decodeIDs(String(cString: sqlite3_column_text(stmt, 5)))
            let mem = decodeIDs(String(cString: sqlite3_column_text(stmt, 6)))
            episodes.append(Episode(id: id, startedAt: started, endedAt: ended, dominantApp: app, topicHint: topic, observationIDs: obs, memoryIDs: mem))
        }
        return episodes
    }

    private func createEpisode(app: String, topicHint: String?, observationID: UUID, memoryID: UUID?) throws -> UUID {
        let episode = Episode(
            id: UUID(), startedAt: Date(), endedAt: Date(), dominantApp: app,
            topicHint: topicHint, observationIDs: [observationID],
            memoryIDs: memoryID.map { [$0] } ?? []
        )
        try save(episode)
        return episode.id
    }

    private func fetch(id: UUID) throws -> Episode? {
        try fetchRecent(limit: 100).first { $0.id == id }
    }

    private func save(_ episode: Episode) throws {
        let sql = """
        INSERT OR REPLACE INTO episodes
        (id, started_at, ended_at, dominant_app, topic_hint, observation_ids, memory_ids)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, episode.id.uuidString, -1, transient)
        sqlite3_bind_double(stmt, 2, episode.startedAt.timeIntervalSince1970)
        if let ended = episode.endedAt {
            sqlite3_bind_double(stmt, 3, ended.timeIntervalSince1970)
        } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, episode.dominantApp, -1, transient)
        if let topic = episode.topicHint {
            sqlite3_bind_text(stmt, 5, topic, -1, transient)
        } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_text(stmt, 6, encodeIDs(episode.observationIDs), -1, transient)
        sqlite3_bind_text(stmt, 7, encodeIDs(episode.memoryIDs), -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to save episode")
        }
    }

    private func encodeIDs(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    private func decodeIDs(_ value: String) -> [UUID] {
        value.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
