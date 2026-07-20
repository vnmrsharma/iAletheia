import Foundation

final class MemoryAdmissionEngine {
    func preliminaryScore(
        attention: Double,
        visibleDuration: Double,
        interaction: InteractionSignals,
        sourceValue: Double,
        changeSignificance: Double,
        sensitivity: Double
    ) -> Double {
        let interactionScore = [
            interaction.keyboardActivity,
            interaction.textWasSelected,
            interaction.contentWasCopied,
            interaction.pageWasRevisited
        ].filter { $0 }.count
        let interactionValue = Double(interactionScore) / 4.0
        return max(0, min(1,
            0.30 * attention +
            0.25 * min(1.0, visibleDuration / 120.0) +
            0.20 * interactionValue +
            0.15 * sourceValue +
            0.10 * changeSignificance -
            0.40 * sensitivity
        ))
    }

    func finalStoreScore(candidate: MemoryCandidate, sensitivity: Double, redundancy: Double) -> Double {
        max(0, min(1,
            0.22 * candidate.futureUtility +
            0.18 * candidate.suggestedImportance +
            0.15 * candidate.actionability +
            0.13 * candidate.explicitness +
            0.10 * candidate.suggestedConfidence +
            0.10 * (1.0 - candidate.transience) +
            0.10 * candidate.suggestedConfidence -
            0.28 * sensitivity -
            0.18 * redundancy -
            0.12 * candidate.transience
        ))
    }

    func decision(for storeScore: Double, sensitivity: Double) -> (MemoryState?, String) {
        if sensitivity >= AdmissionConfig.sensitivityRejectThreshold {
            return (nil, "rejected_sensitive")
        }
        if storeScore >= AdmissionConfig.storeDurableThreshold {
            return (.durable, "stored_durable")
        }
        if storeScore >= AdmissionConfig.storeTemporaryThreshold {
            return (.temporary, "stored_temporary")
        }
        return (nil, "rejected_low_value")
    }
}

final class MemoryDeduplicator {
    func operation(
        candidate: MemoryCandidate,
        existing: [Memory],
        vectorStore: VectorStore
    ) -> (MemoryOperation, Memory?, Double) {
        let embedding = vectorStore.embed(text: candidate.title + " " + candidate.summary)
        var best: (Memory, Double)?
        for memory in existing where !memory.isUserCorrected {
            if let url = candidate.sourceURL, url == memory.sourceURL {
                return (.update, memory, 0.95)
            }
            let existingEmbedding = memory.embedding ?? vectorStore.embed(text: memory.title + " " + memory.summary)
            let similarity = cosineSimilarity(embedding, existingEmbedding)
            if similarity > (best?.1 ?? 0) {
                best = (memory, similarity)
            }
        }
        guard let best else { return (.add, nil, 0) }
        if best.1 >= 0.92 { return (.update, best.0, best.1) }
        if best.1 >= 0.82 { return (.consolidate, best.0, best.1) }
        if best.1 >= 0.65 { return (.add, best.0, best.1) }
        return (.add, nil, best.1)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<count { dot += a[i] * b[i] }
        return Double(dot)
    }
}

final class MemoryConsolidator {
    func maybeConsolidate(
        candidate: MemoryCandidate,
        target: Memory,
        existingSummary: String
    ) -> String {
        let incoming = candidate.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if incoming.isEmpty { return existing }
        if existing.isEmpty { return incoming }
        if incoming == existing { return existing }
        if existing.contains(incoming) { return existing }
        // Prefer the richer, newer summary instead of concatenating OCR fragments.
        if incoming.count >= existing.count / 2 {
            return incoming
        }
        return existing
    }
}

final class MemoryLinker {
    func link(sourceID: UUID, targetID: UUID, relation: String, strength: Double, database: Database) throws {
        let sql = """
        INSERT OR REPLACE INTO memory_links
        (source_memory_id, target_memory_id, relation_type, relation_strength, created_at)
        VALUES (?, ?, ?, ?, ?);
        """
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sourceID.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, targetID.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 3, relation, -1, transient)
        sqlite3_bind_double(stmt, 4, strength)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }
}

final class MemoryDecayService {
    func applyDecay(memoryRepository: MemoryRepository) throws {
        let memories = try memoryRepository.fetchActive()
        let now = Date()
        for var memory in memories where !memory.isPinned {
            let ageDays = now.timeIntervalSince(memory.lastObservedAt) / 86400
            let decayRate: Double
            switch memory.type {
            case .temporaryContext: decayRate = 0.50
            case .webpage: decayRate = 0.06
            case .research: decayRate = 0.02
            case .decision, .project: decayRate = 0.01
            case .userPreference, .communicationPreference: decayRate = 0.005
            default: decayRate = 0.04
            }
            let effective = memory.importance * memory.confidence * exp(-decayRate * ageDays)
            if effective < 0.15, memory.memoryState != .expired {
                memory.memoryState = .expired
                memory.updatedAt = now
                try memoryRepository.save(memory)
            }
        }
    }
}

import SQLite3
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
