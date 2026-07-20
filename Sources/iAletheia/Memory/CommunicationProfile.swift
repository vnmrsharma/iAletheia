import Foundation

/// Learned communication patterns from how the user writes and interacts with the agent.
struct CommunicationProfile: Codable, Equatable {
    var queryCount: Int = 0
    var averageQueryWords: Double = 0
    var averageQueryChars: Double = 0
    var prefersConcise: Double = 0.5
    var prefersDetailed: Double = 0.5
    var technicalDensity: Double = 0.5
    var directQuestionRatio: Double = 0.5
    var commonOpeners: [String] = []
    var recurringTopics: [String] = []
    var lastUpdated: Date = Date()

    mutating func observe(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let words = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wordCount = Double(words.count)
        let charCount = Double(trimmed.count)

        queryCount += 1
        let n = Double(queryCount)
        averageQueryWords = ((averageQueryWords * (n - 1)) + wordCount) / n
        averageQueryChars = ((averageQueryChars * (n - 1)) + charCount) / n

        if wordCount <= 6 { prefersConcise = min(1, prefersConcise + 0.08) }
        if wordCount >= 18 { prefersDetailed = min(1, prefersDetailed + 0.08) }

        let lower = trimmed.lowercased()
        if lower.contains("in detail") || lower.contains("explain more") || lower.contains("elaborate") {
            prefersDetailed = min(1, prefersDetailed + 0.15)
            prefersConcise = max(0, prefersConcise - 0.1)
        }
        if lower.contains("brief") || lower.contains("short answer") || lower.contains("tldr") || lower.contains("quickly") {
            prefersConcise = min(1, prefersConcise + 0.15)
            prefersDetailed = max(0, prefersDetailed - 0.1)
        }

        let techTerms = ["api", "code", "swift", "python", "model", "llm", "database", "sql", "deploy", "github"]
        if techTerms.contains(where: { lower.contains($0) }) {
            technicalDensity = min(1, technicalDensity + 0.06)
        }

        if trimmed.hasSuffix("?") {
            directQuestionRatio = min(1, directQuestionRatio + 0.04)
        }

        recordOpener(from: words)
        recordTopics(from: words)
        lastUpdated = Date()
    }

    func learnedInstructions() -> String {
        guard queryCount >= 3 else { return "" }
        var lines: [String] = ["Learned from how the user communicates:"]

        if prefersConcise > 0.62 {
            lines.append("- User tends to write short, direct queries — keep replies concise unless they ask for detail.")
        } else if prefersDetailed > 0.62 {
            lines.append("- User often asks expansive questions — provide thorough, structured answers.")
        }

        if technicalDensity > 0.58 {
            lines.append("- User is comfortable with technical language — you can use precise technical terms.")
        } else if technicalDensity < 0.38 {
            lines.append("- User prefers plain language over jargon.")
        }

        if directQuestionRatio > 0.65 {
            lines.append("- User asks direct questions — answer the question first, then add context.")
        }

        if !recurringTopics.isEmpty {
            lines.append("- Recurring interests: \(recurringTopics.prefix(5).joined(separator: ", ")).")
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    private mutating func recordOpener(from words: [String]) {
        guard let first = words.first?.lowercased(), first.count >= 2 else { return }
        let opener = words.prefix(2).joined(separator: " ").lowercased()
        var counts = Dictionary(uniqueKeysWithValues: commonOpeners.map { ($0, 1) })
        counts[opener, default: 0] += 1
        commonOpeners = counts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
    }

    private mutating func recordTopics(from words: [String]) {
        let stop: Set<String> = ["what", "when", "where", "how", "why", "did", "was", "were", "about", "from", "that", "this", "with", "have", "your", "mine"]
        for word in words where word.count > 3 && !stop.contains(word.lowercased()) {
            var counts = Dictionary(uniqueKeysWithValues: recurringTopics.map { ($0, 1) })
            counts[word.lowercased(), default: 0] += 1
            recurringTopics = counts.sorted { $0.value > $1.value }.prefix(8).map(\.key)
        }
    }
}
