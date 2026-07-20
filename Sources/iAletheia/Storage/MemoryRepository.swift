import Foundation
import SQLite3

final class MemoryRepository {
    let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(_ memory: Memory) throws {
        let sql = """
        INSERT INTO memories (
            id, type, title, content, summary, source_application, source_title, source_url,
            first_observed_at, last_observed_at, occurrence_count, importance, confidence,
            sensitivity, novelty, attention, future_utility, memory_state, expires_at,
            is_pinned, is_user_corrected, embedding, cloud_processed, admission_reason,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type=excluded.type, title=excluded.title, content=excluded.content, summary=excluded.summary,
            source_application=excluded.source_application, source_title=excluded.source_title,
            source_url=excluded.source_url, last_observed_at=excluded.last_observed_at,
            occurrence_count=excluded.occurrence_count, importance=excluded.importance,
            confidence=excluded.confidence, sensitivity=excluded.sensitivity, novelty=excluded.novelty,
            attention=excluded.attention, future_utility=excluded.future_utility,
            memory_state=excluded.memory_state, expires_at=excluded.expires_at,
            is_pinned=excluded.is_pinned, is_user_corrected=excluded.is_user_corrected,
            embedding=excluded.embedding, cloud_processed=excluded.cloud_processed,
            admission_reason=excluded.admission_reason, updated_at=excluded.updated_at;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let embeddingData = memory.embedding.flatMap { VectorStore.encode($0) }
        try bindMemory(stmt, memory: memory, embeddingData: embeddingData)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to save memory")
        }
        try saveRelations(memory)
    }

    func fetchAll(limit: Int = 200) throws -> [Memory] {
        let sql = """
        SELECT * FROM memories
        WHERE memory_state NOT IN ('deleted', 'superseded')
        ORDER BY last_observed_at DESC LIMIT ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return try fetchMemories(from: stmt)
    }

    func fetch(id: UUID) throws -> Memory? {
        let sql = "SELECT * FROM memories WHERE id = ? LIMIT 1;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        let results = try fetchMemories(from: stmt)
        return results.first
    }

    func fetchSimilarCandidates(limit: Int = 5) throws -> [Memory] {
        try fetchAll(limit: limit)
    }

    func delete(id: UUID) throws {
        try database.exec("UPDATE memories SET memory_state = 'deleted' WHERE id = '\(id.uuidString)';")
    }

    func setPinned(id: UUID, pinned: Bool) throws {
        try database.exec("UPDATE memories SET is_pinned = \(pinned ? 1 : 0) WHERE id = '\(id.uuidString)';")
    }

    func fetchByEntityName(_ normalizedName: String, limit: Int = 20) throws -> [Memory] {
        let sql = """
        SELECT m.* FROM memories m
        JOIN memory_entities e ON e.memory_id = m.id
        WHERE e.normalized_name = ? AND m.memory_state NOT IN ('deleted', 'expired', 'superseded')
        ORDER BY m.last_observed_at DESC LIMIT ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, normalizedName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return try fetchMemories(from: stmt)
    }

    func saveEntityCluster(_ cluster: EntityCluster) throws {
        let sql = """
        INSERT INTO entity_clusters (
            id, normalized_name, entity_type, display_name, disambiguator, unified_summary,
            anchor_memory_id, memory_ids, source_domains, first_seen_at, last_seen_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            display_name=excluded.display_name,
            disambiguator=excluded.disambiguator,
            unified_summary=excluded.unified_summary,
            anchor_memory_id=excluded.anchor_memory_id,
            memory_ids=excluded.memory_ids,
            source_domains=excluded.source_domains,
            last_seen_at=excluded.last_seen_at;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cluster.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, cluster.normalizedName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, cluster.entityType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, cluster.displayName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, cluster.disambiguator, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, cluster.unifiedSummary, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, cluster.anchorMemoryID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, cluster.memoryIDs.map(\.uuidString).joined(separator: ","), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, cluster.sourceDomains.joined(separator: ","), -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 10, cluster.firstSeenAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 11, cluster.lastSeenAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed("Failed to save entity cluster")
        }
    }

    func fetchEntityClusters(limit: Int = 50) throws -> [EntityCluster] {
        let sql = "SELECT * FROM entity_clusters ORDER BY last_seen_at DESC LIMIT ?;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var clusters: [EntityCluster] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)),
                  let anchorText = sqlite3_column_text(stmt, 6),
                  let anchorID = UUID(uuidString: String(cString: anchorText)) else { continue }
            let memoryIDs = String(cString: sqlite3_column_text(stmt, 7))
                .split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            let domains = String(cString: sqlite3_column_text(stmt, 8))
                .split(separator: ",").map(String.init)
            clusters.append(EntityCluster(
                id: id,
                normalizedName: String(cString: sqlite3_column_text(stmt, 1)),
                entityType: String(cString: sqlite3_column_text(stmt, 2)),
                displayName: String(cString: sqlite3_column_text(stmt, 3)),
                disambiguator: String(cString: sqlite3_column_text(stmt, 4)),
                unifiedSummary: String(cString: sqlite3_column_text(stmt, 5)),
                anchorMemoryID: anchorID,
                memoryIDs: memoryIDs,
                sourceDomains: domains,
                firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            ))
        }
        return clusters
    }

    func fetchActive(excludingStates: [MemoryState] = [.deleted, .expired, .superseded]) throws -> [Memory] {
        let excluded = excludingStates.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let sql = "SELECT * FROM memories WHERE memory_state NOT IN (\(excluded));"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try fetchMemories(from: stmt)
    }

    private func bindMemory(_ stmt: OpaquePointer?, memory: Memory, embeddingData: Data?) throws {
        let cols: [Any?] = [
            memory.id.uuidString, memory.type.rawValue, memory.title, memory.content, memory.summary,
            memory.sourceApplication, memory.sourceTitle, memory.sourceURL,
            memory.firstObservedAt.timeIntervalSince1970, memory.lastObservedAt.timeIntervalSince1970,
            memory.occurrenceCount, memory.importance, memory.confidence, memory.sensitivity,
            memory.novelty, memory.attention, memory.futureUtility, memory.memoryState.rawValue,
            memory.expiresAt?.timeIntervalSince1970, memory.isPinned ? 1 : 0, memory.isUserCorrected ? 1 : 0,
            embeddingData as Any?, memory.cloudProcessed ? 1 : 0, memory.admissionReason,
            memory.createdAt.timeIntervalSince1970, memory.updatedAt.timeIntervalSince1970
        ]
        for (index, value) in cols.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case let string as String:
                sqlite3_bind_text(stmt, i, string, -1, SQLITE_TRANSIENT)
            case let int as Int:
                sqlite3_bind_int(stmt, i, Int32(int))
            case let double as Double:
                sqlite3_bind_double(stmt, i, double)
            case let data as Data:
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, i, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case nil:
                sqlite3_bind_null(stmt, i)
            default:
                break
            }
        }
    }

    private func saveRelations(_ memory: Memory) throws {
        try database.exec("DELETE FROM memory_topics WHERE memory_id = '\(memory.id.uuidString)';")
        try database.exec("DELETE FROM memory_keywords WHERE memory_id = '\(memory.id.uuidString)';")
        try database.exec("DELETE FROM memory_entities WHERE memory_id = '\(memory.id.uuidString)';")
        for topic in memory.topics {
            let escaped = topic.replacingOccurrences(of: "'", with: "''")
            try database.exec("INSERT OR IGNORE INTO memory_topics VALUES ('\(memory.id.uuidString)', '\(escaped)');")
        }
        for keyword in memory.keywords {
            let escaped = keyword.replacingOccurrences(of: "'", with: "''")
            try database.exec("INSERT OR IGNORE INTO memory_keywords VALUES ('\(memory.id.uuidString)', '\(escaped)');")
        }
        for entity in memory.entities {
            let escapedName = entity.name.replacingOccurrences(of: "'", with: "''")
            let escapedContext = entity.context?.replacingOccurrences(of: "'", with: "''") ?? ""
            if escapedContext.isEmpty {
                try database.exec("""
                INSERT OR REPLACE INTO memory_entities VALUES (
                    '\(entity.id.uuidString)', '\(memory.id.uuidString)', '\(entity.type)',
                    '\(escapedName)', '\(entity.normalizedName)', NULL
                );
                """)
            } else {
                try database.exec("""
                INSERT OR REPLACE INTO memory_entities VALUES (
                    '\(entity.id.uuidString)', '\(memory.id.uuidString)', '\(entity.type)',
                    '\(escapedName)', '\(entity.normalizedName)', '\(escapedContext)'
                );
                """)
            }
        }
    }

    private func fetchMemories(from stmt: OpaquePointer?) throws -> [Memory] {
        var results: [Memory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let type = MemoryType(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .webpage
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let summary = String(cString: sqlite3_column_text(stmt, 4))
            let sourceApp = String(cString: sqlite3_column_text(stmt, 5))
            let sourceTitle = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let sourceURL = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let firstObserved = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            let lastObserved = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
            let occurrence = Int(sqlite3_column_int(stmt, 10))
            let importance = sqlite3_column_double(stmt, 11)
            let confidence = sqlite3_column_double(stmt, 12)
            let sensitivity = sqlite3_column_double(stmt, 13)
            let novelty = sqlite3_column_double(stmt, 14)
            let attention = sqlite3_column_double(stmt, 15)
            let futureUtility = sqlite3_column_double(stmt, 16)
            let state = MemoryState(rawValue: String(cString: sqlite3_column_text(stmt, 17))) ?? .durable
            let expiresAt = sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 18))
            let isPinned = sqlite3_column_int(stmt, 19) == 1
            let isUserCorrected = sqlite3_column_int(stmt, 20) == 1
            var embedding: [Float]? = nil
            if sqlite3_column_type(stmt, 21) != SQLITE_NULL,
               let blob = sqlite3_column_blob(stmt, 21) {
                let count = Int(sqlite3_column_bytes(stmt, 21))
                embedding = VectorStore.decode(Data(bytes: blob, count: count))
            }
            let cloudProcessed = sqlite3_column_int(stmt, 22) == 1
            let admissionReason = sqlite3_column_text(stmt, 23).map { String(cString: $0) }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 24))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 25))

            let topics = try fetchStrings(table: "memory_topics", column: "topic", memoryID: id)
            let keywords = try fetchStrings(table: "memory_keywords", column: "keyword", memoryID: id)
            let entities = try fetchEntities(memoryID: id)
            let related = try fetchRelatedMemoryIDs(memoryID: id)

            results.append(Memory(
                id: id, type: type, title: title, content: content, summary: summary,
                topics: topics, keywords: keywords, entities: entities,
                sourceApplication: sourceApp, sourceTitle: sourceTitle, sourceURL: sourceURL,
                firstObservedAt: firstObserved, lastObservedAt: lastObserved, occurrenceCount: occurrence,
                importance: importance, confidence: confidence, sensitivity: sensitivity,
                novelty: novelty, attention: attention, futureUtility: futureUtility,
                memoryState: state, expiresAt: expiresAt, isPinned: isPinned, isUserCorrected: isUserCorrected,
                embedding: embedding, relatedMemoryIDs: related, evidenceObservationIDs: [],
                cloudProcessed: cloudProcessed, admissionReason: admissionReason,
                createdAt: createdAt, updatedAt: updatedAt
            ))
        }
        return results
    }

    private func fetchStrings(table: String, column: String, memoryID: UUID) throws -> [String] {
        let sql = "SELECT \(column) FROM \(table) WHERE memory_id = ?;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, memoryID.uuidString, -1, SQLITE_TRANSIENT)
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            values.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return values
    }

    private func fetchEntities(memoryID: UUID) throws -> [MemoryEntity] {
        let sql = "SELECT id, entity_type, name, context FROM memory_entities WHERE memory_id = ?;"
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, memoryID.uuidString, -1, SQLITE_TRANSIENT)
        var entities: [MemoryEntity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idText)) else { continue }
            let type = String(cString: sqlite3_column_text(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let context = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            entities.append(MemoryEntity(id: id, type: type, name: name, context: context))
        }
        return entities
    }

    private func fetchRelatedMemoryIDs(memoryID: UUID) throws -> [UUID] {
        let sql = """
        SELECT target_memory_id FROM memory_links WHERE source_memory_id = ?
        UNION SELECT source_memory_id FROM memory_links WHERE target_memory_id = ?;
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, memoryID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, memoryID.uuidString, -1, SQLITE_TRANSIENT)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: text)) {
                ids.append(id)
            }
        }
        return ids
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
