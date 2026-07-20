import Foundation

final class QueryInterpreter {
    func parseRelativeTime(query: String, now: Date = Date()) -> TimeRangeFilter? {
        let lower = query.lowercased()
        let calendar = Calendar.current
        if lower.contains("yesterday") {
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now)!)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return TimeRangeFilter(type: .absolute, relativeValue: "yesterday", start: start, end: end)
        }
        if lower.contains("today") {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return TimeRangeFilter(type: .absolute, relativeValue: "today", start: start, end: end)
        }
        if lower.contains("last week") {
            let start = calendar.date(byAdding: .day, value: -7, to: now)!
            return TimeRangeFilter(type: .absolute, relativeValue: "last_week", start: start, end: now)
        }
        return nil
    }

    func interpretLocally(query: String) -> SearchIntent {
        SearchIntent(
            intent: "recall",
            semanticQuery: query,
            keywords: query
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 },
            relatedConcepts: [],
            timeRange: parseRelativeTime(query: query),
            sourceTypes: ["research", "webpage", "document"],
            requestedOutput: ["summary", "links"]
        )
    }
}

final class HybridRetriever {
    private let memoryRepository: MemoryRepository
    private let searchIndex: SearchIndex
    private let vectorStore: VectorStore
    private let queryInterpreter: QueryInterpreter

    init(
        memoryRepository: MemoryRepository,
        searchIndex: SearchIndex,
        vectorStore: VectorStore,
        queryInterpreter: QueryInterpreter
    ) {
        self.memoryRepository = memoryRepository
        self.searchIndex = searchIndex
        self.vectorStore = vectorStore
        self.queryInterpreter = queryInterpreter
    }

    func retrieve(query: String) async throws -> [RankedMemory] {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.retrieveSync(query: query)
        }.value
    }

    private func retrieveSync(query: String) throws -> [RankedMemory] {
        let intent = queryInterpreter.interpretLocally(query: query)
        let expandedTerms = QueryExpander.expandedSearchTerms(for: query)
        let semanticQueries = Array(QueryExpander.semanticQueries(for: query).prefix(2))

        var scores: [UUID: Double] = [:]

        for searchQuery in semanticQueries {
            let ftsResults = (try? searchIndex.search(query: searchQuery, limit: 20)) ?? []
            for (id, score) in ftsResults {
                scores[id, default: 0] += score * 0.22
            }
            for (id, score) in vectorStore.search(query: searchQuery, limit: 20) {
                scores[id, default: 0] += score * 0.34
            }
        }

        var memories = try memoryRepository.fetchActive()
        if let range = intent.timeRange, let start = range.start, let end = range.end {
            memories = memories.filter { $0.lastObservedAt >= start && $0.lastObservedAt <= end }
            for memory in memories {
                scores[memory.id, default: 0] += 0.18
            }
        }

        let candidateIDs = Set(scores.keys)
        let scanPool: [Memory]
        if candidateIDs.count >= 3 {
            scanPool = memories.filter { candidateIDs.contains($0.id) }
        } else {
            scanPool = memories
        }

        for memory in scanPool {
            scores[memory.id, default: 0] += memory.importance * 0.08 + memory.confidence * 0.06 + memory.attention * 0.07
        }

        let terms = expandedTerms.prefix(12)
        for term in terms {
            for memory in scanPool {
                let title = (memory.sourceTitle ?? memory.title).lowercased()
                let summary = memory.summary.lowercased()
                let content = String(memory.content.prefix(1200)).lowercased()
                let keywords = memory.keywords.joined(separator: " ").lowercased()
                let topics = memory.topics.joined(separator: " ").lowercased()

                if title.contains(term) {
                    scores[memory.id, default: 0] += 0.35
                }
                if summary.contains(term) || keywords.contains(term) || topics.contains(term) {
                    scores[memory.id, default: 0] += 0.22
                }
                if content.contains(term) {
                    scores[memory.id, default: 0] += 0.14
                }
                if fuzzyContains(title, term) || fuzzyContains(summary, term) {
                    scores[memory.id, default: 0] += 0.12
                }
            }
        }

        let ranked = memories
            .compactMap { memory -> RankedMemory? in
                guard let score = scores[memory.id], score > 0.05 else { return nil }
                return RankedMemory(memory: memory, score: score)
            }
            .sorted { $0.score > $1.score }

        return Array(ranked.prefix(8))
    }

    private func fuzzyContains(_ haystack: String, _ needle: String) -> Bool {
        guard needle.count > 4 else { return false }
        let stem = String(needle.prefix(needle.count - 1))
        return haystack.contains(stem)
    }
}
