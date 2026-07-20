import Foundation

final class MemoryExtractionService {
    private let localExtractor: LocalMemoryExtractor
    private let qwenClient: QwenClient

    init(localExtractor: LocalMemoryExtractor, qwenClient: QwenClient) {
        self.localExtractor = localExtractor
        self.qwenClient = qwenClient
    }

    func extract(from processed: ProcessedObservation, attentionScore: Double) async -> [MemoryCandidate] {
        var candidates = localExtractor.extract(from: processed, attentionScore: attentionScore)
        guard var base = candidates.first else { return [] }

        let cloudEnabled = AppConfiguration.cloudProcessingEnabled
        guard cloudEnabled, processed.cloudProcessingAllowed, qwenClient.isConfigured else {
            return candidates
        }

        do {
            let enriched = try await qwenClient.extractMemories(from: processed)
            if let cloud = enriched.first {
                base = merge(local: base, cloud: cloud)
                candidates[0] = base
            }
        } catch {
            // Keep the improved local summary when cloud enrichment fails.
        }

        return candidates
    }

    private func merge(local: MemoryCandidate, cloud: MemoryCandidate) -> MemoryCandidate {
        MemoryCandidate(
            id: local.id,
            type: cloud.type != .document ? cloud.type : local.type,
            title: local.title,
            content: local.content,
            summary: cloud.summary.isEmpty ? local.summary : cloud.summary,
            topics: cloud.topics.isEmpty ? local.topics : cloud.topics,
            keywords: cloud.keywords.isEmpty ? local.keywords : cloud.keywords,
            entities: mergeEntities(local.entities, cloud.entities),
            suggestedImportance: max(local.suggestedImportance, cloud.suggestedImportance),
            suggestedConfidence: max(local.suggestedConfidence, cloud.suggestedConfidence),
            suggestedExpiry: local.suggestedExpiry,
            sourceURL: local.sourceURL,
            sourceTitle: local.sourceTitle,
            futureUtility: max(local.futureUtility, cloud.futureUtility),
            actionability: max(local.actionability, cloud.actionability),
            explicitness: max(local.explicitness, cloud.explicitness),
            transience: min(local.transience, cloud.transience)
        )
    }

    private func mergeEntities(_ local: [MemoryEntity], _ cloud: [MemoryEntity]) -> [MemoryEntity] {
        var byKey: [String: MemoryEntity] = [:]
        for entity in local + cloud {
            let key = entity.normalizedName + "|" + (entity.context ?? "")
            if let existing = byKey[key] {
                if entity.name.count > existing.name.count { byKey[key] = entity }
            } else {
                byKey[key] = entity
            }
        }
        return Array(byKey.values)
    }
}

enum AppConfiguration {
    private static let cloudKey = "ialetheia.cloudProcessingEnabled"

    static var cloudProcessingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: cloudKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: cloudKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: cloudKey) }
    }
}
