import Foundation

struct EntityCluster: Codable, Equatable, Identifiable {
    let id: UUID
    var normalizedName: String
    var entityType: String
    var displayName: String
    var disambiguator: String
    var unifiedSummary: String
    var anchorMemoryID: UUID
    var memoryIDs: [UUID]
    var sourceDomains: [String]
    var firstSeenAt: Date
    var lastSeenAt: Date

    init(
        id: UUID = UUID(),
        normalizedName: String,
        entityType: String,
        displayName: String,
        disambiguator: String,
        unifiedSummary: String,
        anchorMemoryID: UUID,
        memoryIDs: [UUID] = [],
        sourceDomains: [String] = [],
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.normalizedName = normalizedName
        self.entityType = entityType
        self.displayName = displayName
        self.disambiguator = disambiguator
        self.unifiedSummary = unifiedSummary
        self.anchorMemoryID = anchorMemoryID
        self.memoryIDs = memoryIDs
        self.sourceDomains = sourceDomains
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

struct SmartMemoryDecision: Equatable {
    let operation: MemoryOperation
    let targetMemory: Memory?
    let similarity: Double
    let relation: String?
    let unifiedSummary: String?
    let mergedEntities: [MemoryEntity]
    let entityClusterID: UUID?
    let isHomonym: Bool
}

/// Entity-aware memory intelligence: merge same-topic memories, split homonyms, synthesize unified summaries.
final class SmartEntityMemoryService {
    private let memoryRepository: MemoryRepository
    private let memoryLinker: MemoryLinker
    private let memoryConsolidator: MemoryConsolidator
    private let qwenClient: QwenClient

    init(
        memoryRepository: MemoryRepository,
        memoryLinker: MemoryLinker,
        memoryConsolidator: MemoryConsolidator,
        qwenClient: QwenClient
    ) {
        self.memoryRepository = memoryRepository
        self.memoryLinker = memoryLinker
        self.memoryConsolidator = memoryConsolidator
        self.qwenClient = qwenClient
    }

    func decide(
        candidate: MemoryCandidate,
        observation: ProcessedObservation,
        basicOperation: MemoryOperation,
        basicTarget: Memory?,
        basicSimilarity: Double,
        existing: [Memory],
        vectorStore: VectorStore
    ) -> SmartMemoryDecision {
        let fingerprint = contextFingerprint(candidate: candidate, observation: observation)
        let primaryEntity = dominantEntity(from: candidate)

        if let entity = primaryEntity {
            return decideWithEntity(
                entity: entity,
                fingerprint: fingerprint,
                candidate: candidate,
                observation: observation,
                basicOperation: basicOperation,
                basicTarget: basicTarget,
                basicSimilarity: basicSimilarity,
                existing: existing,
                vectorStore: vectorStore
            )
        }

        if let topicMatch = findTopicAnchor(candidate: candidate, existing: existing, vectorStore: vectorStore) {
            let summary = synthesizeUnifiedSummary(
                entityName: topicMatch.memory.title,
                existingSummary: topicMatch.memory.summary,
                incomingSummary: candidate.summary,
                occurrenceCount: topicMatch.memory.occurrenceCount + 1,
                sources: sourceLabels(existing: topicMatch.memory, incoming: candidate)
            )
            return SmartMemoryDecision(
                operation: .consolidate,
                targetMemory: topicMatch.memory,
                similarity: topicMatch.similarity,
                relation: "same_topic",
                unifiedSummary: summary,
                mergedEntities: mergeEntities(existing: topicMatch.memory.entities, incoming: candidate.entities),
                entityClusterID: nil,
                isHomonym: false
            )
        }

        return SmartMemoryDecision(
            operation: basicOperation,
            targetMemory: basicTarget,
            similarity: basicSimilarity,
            relation: basicSimilarity >= 0.65 ? "related" : nil,
            unifiedSummary: nil,
            mergedEntities: candidate.entities,
            entityClusterID: nil,
            isHomonym: false
        )
    }

    func consolidateExistingMemories(vectorStore: VectorStore) throws -> Int {
        let memories = try memoryRepository.fetchActive()
        var mergedCount = 0
        var processed = Set<UUID>()

        let personGroups = Dictionary(grouping: memories) { memory -> String? in
            dominantEntity(from: memory)?.normalizedName
        }

        for (normalizedName, group) in personGroups where normalizedName != nil && group.count > 1 {
            let group = group
            let clusters = clusterMemories(group, vectorStore: vectorStore)

            for cluster in clusters where cluster.count > 1 {
                guard let anchor = cluster.max(by: { $0.importance < $1.importance || ($0.importance == $1.importance && $0.firstObservedAt > $1.firstObservedAt) }) else { continue }
                if processed.contains(anchor.id) { continue }

                var unifiedSummary = anchor.summary
                var allEntities = anchor.entities
                var allTopics = anchor.topics
                var allKeywords = anchor.keywords
                var occurrence = anchor.occurrenceCount
                var domains = domain(from: anchor.sourceURL).map { [$0] } ?? []

                for other in cluster where other.id != anchor.id && !processed.contains(other.id) {
                    unifiedSummary = synthesizeUnifiedSummary(
                        entityName: anchor.title,
                        existingSummary: unifiedSummary,
                        incomingSummary: other.summary,
                        occurrenceCount: occurrence + 1,
                        sources: [anchor.sourceTitle ?? anchor.title, other.sourceTitle ?? other.title]
                    )
                    allEntities = mergeEntities(existing: allEntities, incoming: other.entities)
                    allTopics = mergeUnique(allTopics, other.topics, limit: 10)
                    allKeywords = mergeUnique(allKeywords, other.keywords, limit: 12)
                    occurrence += other.occurrenceCount
                    if let d = domain(from: other.sourceURL) { domains.append(d) }
                    try memoryLinker.link(
                        sourceID: other.id, targetID: anchor.id,
                        relation: "superseded_by", strength: 0.95,
                        database: memoryRepository.database
                    )
                    var superseded = other
                    superseded.memoryState = .superseded
                    superseded.updatedAt = Date()
                    try memoryRepository.save(superseded)
                    processed.insert(other.id)
                    mergedCount += 1
                }

                var updated = anchor
                updated.summary = unifiedSummary
                updated.entities = allEntities
                updated.topics = allTopics
                updated.keywords = allKeywords
                updated.occurrenceCount = occurrence
                updated.memoryState = .consolidated
                updated.type = .person
                updated.title = displayTitle(for: anchor, entities: allEntities)
                updated.lastObservedAt = cluster.map(\.lastObservedAt).max() ?? anchor.lastObservedAt
                updated.updatedAt = Date()
                try memoryRepository.save(updated)

                if let name = normalizedName {
                    try memoryRepository.saveEntityCluster(EntityCluster(
                        normalizedName: name,
                        entityType: "person",
                        displayName: updated.title,
                        disambiguator: domains.sorted().prefix(3).joined(separator: "|"),
                        unifiedSummary: unifiedSummary,
                        anchorMemoryID: anchor.id,
                        memoryIDs: cluster.map(\.id),
                        sourceDomains: Array(Set(domains)),
                        firstSeenAt: cluster.map(\.firstObservedAt).min() ?? anchor.firstObservedAt,
                        lastSeenAt: updated.lastObservedAt
                    ))
                }
                processed.insert(anchor.id)
            }
        }

        return mergedCount
    }

    func applyMerge(
        decision: SmartMemoryDecision,
        candidate: MemoryCandidate,
        existingMemory: inout Memory,
        embedding: [Float],
        now: Date
    ) {
        if let unified = decision.unifiedSummary {
            existingMemory.summary = unified
        } else {
            existingMemory.summary = memoryConsolidator.maybeConsolidate(
                candidate: candidate,
                target: existingMemory,
                existingSummary: existingMemory.summary
            )
        }
        existingMemory.entities = decision.mergedEntities
        existingMemory.topics = mergeUnique(existingMemory.topics, candidate.topics, limit: 10)
        existingMemory.keywords = mergeUnique(existingMemory.keywords, candidate.keywords, limit: 12)
        existingMemory.content = candidate.content
        existingMemory.lastObservedAt = now
        existingMemory.occurrenceCount += 1
        existingMemory.embedding = embedding
        existingMemory.memoryState = .consolidated
        existingMemory.updatedAt = now
        existingMemory.importance = min(1, max(existingMemory.importance, candidate.suggestedImportance) + 0.04)
        existingMemory.confidence = min(1, existingMemory.confidence + 0.02)

        if let entity = dominantEntity(from: candidate) {
            existingMemory.title = displayTitle(for: existingMemory, entities: decision.mergedEntities)
            if existingMemory.type == .webpage || existingMemory.type == .document {
                existingMemory.type = entity.type == "person" ? .person : .research
            }
        }
    }

    // MARK: - Private

    private func decideWithEntity(
        entity: MemoryEntity,
        fingerprint: Set<String>,
        candidate: MemoryCandidate,
        observation: ProcessedObservation,
        basicOperation: MemoryOperation,
        basicTarget: Memory?,
        basicSimilarity: Double,
        existing: [Memory],
        vectorStore: VectorStore
    ) -> SmartMemoryDecision {
        let candidates = existing.filter { memory in
            !memory.isUserCorrected && memory.memoryState != .superseded &&
            memory.entities.contains { $0.normalizedName == entity.normalizedName || namesOverlap($0.name, entity.name) }
        }

        var bestMatch: (memory: Memory, score: Double, isHomonym: Bool)?

        for memory in candidates {
            let memoryFingerprint = contextFingerprint(memory: memory)
            let overlap = jaccard(fingerprint, memoryFingerprint)
            let embedding = vectorStore.embed(text: candidate.title + " " + candidate.summary)
            let existingEmbedding = memory.embedding ?? vectorStore.embed(text: memory.title + " " + memory.summary)
            let semantic = cosineSimilarity(embedding, existingEmbedding)
            let combined = overlap * 0.45 + semantic * 0.55

            let domainConflict = hasDomainConflict(
                candidate: candidate, memory: memory, fingerprint: fingerprint, memoryFingerprint: memoryFingerprint
            )
            let isHomonym = domainConflict && combined < 0.72

            if combined > (bestMatch?.score ?? 0) {
                bestMatch = (memory, combined, isHomonym)
            }
        }

        if let best = bestMatch, best.isHomonym {
            return SmartMemoryDecision(
                operation: .add,
                targetMemory: best.memory,
                similarity: best.score,
                relation: "homonym",
                unifiedSummary: candidate.summary,
                mergedEntities: candidate.entities,
                entityClusterID: nil,
                isHomonym: true
            )
        }

        if let best = bestMatch, best.score >= 0.52 {
            let summary = synthesizeUnifiedSummary(
                entityName: entity.name,
                existingSummary: best.memory.summary,
                incomingSummary: candidate.summary,
                occurrenceCount: best.memory.occurrenceCount + 1,
                sources: sourceLabels(existing: best.memory, incoming: candidate)
            )
            let operation: MemoryOperation = best.score >= 0.88 ? .update : .consolidate
            return SmartMemoryDecision(
                operation: operation,
                targetMemory: best.memory,
                similarity: best.score,
                relation: "same_entity",
                unifiedSummary: summary,
                mergedEntities: mergeEntities(existing: best.memory.entities, incoming: candidate.entities),
                entityClusterID: nil,
                isHomonym: false
            )
        }

        if basicOperation == .update || basicOperation == .consolidate, let basicTarget {
            let summary = synthesizeUnifiedSummary(
                entityName: entity.name,
                existingSummary: basicTarget.summary,
                incomingSummary: candidate.summary,
                occurrenceCount: basicTarget.occurrenceCount + 1,
                sources: sourceLabels(existing: basicTarget, incoming: candidate)
            )
            return SmartMemoryDecision(
                operation: basicOperation,
                targetMemory: basicTarget,
                similarity: basicSimilarity,
                relation: "same_topic",
                unifiedSummary: summary,
                mergedEntities: mergeEntities(existing: basicTarget.entities, incoming: candidate.entities),
                entityClusterID: nil,
                isHomonym: false
            )
        }

        return SmartMemoryDecision(
            operation: .add,
            targetMemory: bestMatch?.memory,
            similarity: basicSimilarity,
            relation: bestMatch == nil ? nil : "related_entity",
            unifiedSummary: nil,
            mergedEntities: enrichEntities(candidate.entities, fingerprint: fingerprint, observation: observation),
            entityClusterID: nil,
            isHomonym: false
        )
    }

    private func findTopicAnchor(
        candidate: MemoryCandidate,
        existing: [Memory],
        vectorStore: VectorStore
    ) -> (memory: Memory, similarity: Double)? {
        let embedding = vectorStore.embed(text: candidate.title + " " + candidate.summary)
        var best: (Memory, Double)?
        for memory in existing where !memory.isUserCorrected && memory.memoryState != .superseded {
            let topicOverlap = Set(candidate.topics.map { $0.lowercased() })
                .intersection(memory.topics.map { $0.lowercased() }).count
            guard topicOverlap >= 2 else { continue }
            let existingEmbedding = memory.embedding ?? vectorStore.embed(text: memory.title + " " + memory.summary)
            let semantic = cosineSimilarity(embedding, existingEmbedding)
            let score = semantic + Double(topicOverlap) * 0.08
            if score > (best?.1 ?? 0.65) {
                best = (memory, score)
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    func synthesizeUnifiedSummary(
        entityName: String,
        existingSummary: String,
        incomingSummary: String,
        occurrenceCount: Int,
        sources: [String]
    ) -> String {
        let existing = existingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = incomingSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        if existing.isEmpty { return incoming }
        if incoming.isEmpty { return existing }
        if existing.contains(incoming) || incoming.contains(existing) {
            return existing.count >= incoming.count ? existing : incoming
        }

        let existingFacts = factSentences(from: existing)
        let incomingFacts = factSentences(from: incoming)
        var mergedFacts: [String] = []
        var seen = Set<String>()

        for fact in existingFacts + incomingFacts {
            let key = String(fact.lowercased().prefix(80))
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            mergedFacts.append(fact)
        }

        let body = mergedFacts.prefix(5).joined(separator: " ")
        var lines = ["\(entityName) — unified memory from \(occurrenceCount) related views."]
        if !body.isEmpty { lines.append(body) }
        let uniqueSources = Array(Set(sources)).prefix(4)
        if !uniqueSources.isEmpty {
            lines.append("Seen on: \(uniqueSources.joined(separator: "; ")).")
        }
        return String(lines.joined(separator: " ").prefix(900))
    }

    func contextFingerprint(candidate: MemoryCandidate, observation: ProcessedObservation) -> Set<String> {
        var tokens = Set<String>()
        if let host = domain(from: candidate.sourceURL) { tokens.insert(host) }
        tokens.insert(observation.applicationName.lowercased())
        for entity in candidate.entities {
            tokens.insert(entity.normalizedName)
            if let context = entity.context?.lowercased(), !context.isEmpty {
                tokens.insert(context)
            }
        }
        for topic in candidate.topics.prefix(4) {
            tokens.insert(topic.lowercased())
        }
        for token in titleTokens(candidate.title) {
            tokens.insert(token)
        }
        return tokens
    }

    private func contextFingerprint(memory: Memory) -> Set<String> {
        var tokens = Set<String>()
        if let host = domain(from: memory.sourceURL) { tokens.insert(host) }
        tokens.insert(memory.sourceApplication.lowercased())
        for entity in memory.entities { tokens.insert(entity.normalizedName) }
        for topic in memory.topics.prefix(4) { tokens.insert(topic.lowercased()) }
        for token in titleTokens(memory.title) { tokens.insert(token) }
        return tokens
    }

    private func hasDomainConflict(
        candidate: MemoryCandidate,
        memory: Memory,
        fingerprint: Set<String>,
        memoryFingerprint: Set<String>
    ) -> Bool {
        let candidateDomains = fingerprint.filter { $0.contains(".") }
        let memoryDomains = memoryFingerprint.filter { $0.contains(".") }
        guard !candidateDomains.isEmpty, !memoryDomains.isEmpty else { return false }
        return candidateDomains.isDisjoint(with: memoryDomains)
    }

    private func clusterMemories(_ memories: [Memory], vectorStore: VectorStore) -> [[Memory]] {
        var remaining = memories
        var clusters: [[Memory]] = []

        while let seed = remaining.first {
            remaining.removeAll { $0.id == seed.id }
            var cluster = [seed]
            let seedEmbedding = seed.embedding ?? vectorStore.embed(text: seed.title + " " + seed.summary)
            let seedPrint = contextFingerprint(memory: seed)

            remaining.removeAll { memory in
                let embedding = memory.embedding ?? vectorStore.embed(text: memory.title + " " + memory.summary)
                let semantic = cosineSimilarity(seedEmbedding, embedding)
                let overlap = jaccard(seedPrint, contextFingerprint(memory: memory))
                let combined = semantic * 0.6 + overlap * 0.4
                if combined >= 0.48 {
                    cluster.append(memory)
                    return true
                }
                return false
            }
            clusters.append(cluster)
        }
        return clusters
    }

    private func dominantEntity(from candidate: MemoryCandidate) -> MemoryEntity? {
        if let person = candidate.entities.first(where: { $0.type == "person" }) {
            return person
        }
        return inferPersonFromTitle(candidate.title)
    }

    private func dominantEntity(from memory: Memory) -> MemoryEntity? {
        memory.entities.first(where: { $0.type == "person" }) ?? inferPersonFromTitle(memory.title)
    }

    private func inferPersonFromTitle(_ title: String) -> MemoryEntity? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = title
        var best: MemoryEntity?
        tagger.enumerateTags(in: title.startIndex..<title.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .joinNames]) { tag, range in
            guard tag == .personalName else { return true }
            let name = String(title[range])
            guard name.split(separator: " ").count >= 2 else { return true }
            best = MemoryEntity(type: "person", name: name, context: titleTokens(title).joined(separator: " "))
            return false
        }
        return best
    }

    private func enrichEntities(
        _ entities: [MemoryEntity],
        fingerprint: Set<String>,
        observation: ProcessedObservation
    ) -> [MemoryEntity] {
        let context = fingerprint.filter { $0.contains(".") || $0.contains(" ") }.prefix(3).joined(separator: "|")
        return entities.map { entity in
            MemoryEntity(id: entity.id, type: entity.type, name: entity.name, context: context.isEmpty ? entity.context : context)
        }
    }

    private func mergeEntities(existing: [MemoryEntity], incoming: [MemoryEntity]) -> [MemoryEntity] {
        var byKey: [String: MemoryEntity] = [:]
        for entity in existing + incoming {
            let key = entity.normalizedName + "|" + (entity.context ?? "")
            if let current = byKey[key] {
                if entity.name.count > current.name.count {
                    byKey[key] = entity
                }
            } else {
                byKey[key] = entity
            }
        }
        return Array(byKey.values).sorted { $0.name < $1.name }
    }

    private func displayTitle(for memory: Memory, entities: [MemoryEntity]) -> String {
        if let person = entities.first(where: { $0.type == "person" }) {
            let org = entities.first(where: { $0.type == "organisation" })?.name
            if let org, !org.isEmpty {
                return "\(person.name) — \(org)"
            }
            return person.name
        }
        return memory.title
    }

    private func factSentences(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "While browsing in", with: "While browsing in")
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 24 && !$0.lowercased().hasPrefix("seen on:") }
    }

    private func sourceLabels(existing: Memory, incoming: MemoryCandidate) -> [String] {
        [existing.sourceTitle ?? existing.title, incoming.sourceTitle ?? incoming.title]
            .filter { !$0.isEmpty }
    }

    private func domain(from urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), var host = url.host else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.lowercased()
    }

    private func titleTokens(_ title: String) -> [String] {
        title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 3 && !Self.stopWords.contains($0) }
            .prefix(6)
            .map { $0 }
    }

    private func namesOverlap(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased(), nb = b.lowercased()
        return na.contains(nb) || nb.contains(na)
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<count { dot += a[i] * b[i] }
        return Double(dot)
    }

    private func mergeUnique(_ existing: [String], _ incoming: [String], limit: Int) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for item in incoming {
            let key = item.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(item)
            if merged.count >= limit { break }
        }
        return merged
    }

    private static let stopWords: Set<String> = [
        "about", "from", "with", "that", "this", "your", "page", "view", "profile", "home"
    ]
}

import NaturalLanguage
