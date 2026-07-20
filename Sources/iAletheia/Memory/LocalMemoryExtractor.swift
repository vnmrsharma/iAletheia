import Foundation
import NaturalLanguage

final class LocalMemoryExtractor {
    func extract(from processed: ProcessedObservation, attentionScore: Double) -> [MemoryCandidate] {
        let title = cleanTitle(processed.title ?? processed.applicationName)
        let cleaned = cleanText(processed.redactedText)
        guard cleaned.count >= 40 else { return [] }

        let summary = buildSummary(title: title, text: cleaned, url: processed.url, app: processed.applicationName)
        guard !summary.isEmpty else { return [] }

        let topics = extractTopics(from: cleaned, title: title)
        let keywords = extractKeywords(from: cleaned)
        let entities = extractEntities(from: cleaned, title: title)
        let type = inferType(from: processed, text: cleaned)
        let utility = min(1.0, Double(cleaned.count) / 1200.0 + 0.35)

        return [MemoryCandidate(
            id: UUID(),
            type: type,
            title: title,
            content: processed.redactedText,
            summary: summary,
            topics: topics,
            keywords: keywords,
            entities: entities,
            suggestedImportance: utility,
            suggestedConfidence: 0.78,
            suggestedExpiry: nil,
            sourceURL: processed.url,
            sourceTitle: processed.title,
            futureUtility: utility,
            actionability: processed.url == nil ? 0.4 : 0.72,
            explicitness: 0.55,
            transience: processed.url == nil ? 0.35 : 0.18
        )]
    }

    // MARK: - Summary

    private func buildSummary(title: String, text: String, url: String?, app: String) -> String {
        let sentences = rankedSentences(from: text)
        let body = sentences.prefix(4).joined(separator: " ")
        guard !body.isEmpty else { return "" }

        var parts: [String] = []
        if url != nil {
            parts.append("While browsing in \(app), the user viewed \"\(title)\".")
        } else {
            parts.append("While working in \(app), the user viewed \"\(title)\".")
        }

        let trimmedBody = String(body.prefix(420)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            parts.append(trimmedBody)
        }

        return String(parts.joined(separator: " ").prefix(600))
    }

    private func rankedSentences(from text: String) -> [String] {
        let rawSentences = text
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 25 && $0.count <= 280 }
            .filter { !isNoiseLine($0) }

        let scored = rawSentences.map { sentence -> (String, Double) in
            (sentence, scoreSentence(sentence))
        }
        .sorted { $0.1 > $1.1 }

        var seen = Set<String>()
        return scored.compactMap { sentence, score in
            let key = sentence.lowercased()
            guard score > 0.2, !seen.contains(key) else { return nil }
            seen.insert(key)
            return sentence
        }
    }

    private func scoreSentence(_ sentence: String) -> Double {
        let words = sentence.lowercased().split(separator: " ").map(String.init)
        guard words.count >= 5 else { return 0 }

        var score = 0.35
        score += min(0.25, Double(words.count) / 40.0)

        let uniqueRatio = Double(Set(words).count) / Double(words.count)
        score += uniqueRatio * 0.15

        let capitalized = sentence.filter { $0.isUppercase }.count
        if capitalized > 2 { score += 0.08 }

        if words.contains(where: { $0.count > 8 }) { score += 0.08 }
        if sentence.contains(where: { $0.isNumber }) { score += 0.05 }

        let stopwordRatio = Double(words.filter { Self.stopWords.contains($0) }.count) / Double(words.count)
        score -= stopwordRatio * 0.35

        if isNoiseLine(sentence) { score -= 0.5 }
        return max(0, score)
    }

    // MARK: - Topics & Keywords

    private func extractTopics(from text: String, title: String) -> [String] {
        var topics: [String] = []

        let titleWords = title
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 3 && !Self.stopWords.contains($0.lowercased()) }
        topics.append(contentsOf: titleWords.prefix(3))

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range]).lowercased()
            if word.count > 3, !Self.stopWords.contains(word) {
                topics.append(word)
            }
            return true
        }

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard tag != nil else { return true }
            let name = String(text[range])
            if name.count > 2 { topics.append(name) }
            return true
        }

        return Array(
            topics
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 2 }
                .reduce(into: [String: Int]()) { counts, topic in
                    counts[topic.lowercased(), default: 0] += 1
                }
                .sorted { $0.value > $1.value }
                .prefix(8)
                .map(\.key)
        )
    }

    private func extractKeywords(from text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 4 && !Self.stopWords.contains($0) }

        return Dictionary(grouping: words, by: { $0 })
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map(\.key)
    }

    private func extractEntities(from text: String, title: String = "") -> [MemoryEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text + "\n" + title
        var entities: [MemoryEntity] = []
        var organisations: [String] = []

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard let tag else { return true }
            let name = String(text[range])
            let type: String
            switch tag {
            case .personalName: type = "person"
            case .organizationName:
                type = "organisation"
                organisations.append(name)
            case .placeName: type = "place"
            default: type = "entity"
            }
            if type != "organisation" || name.count > 3 {
                let context = organisations.prefix(2).joined(separator: "|")
                entities.append(MemoryEntity(type: type, name: name, context: context.isEmpty ? nil : context))
            }
            return true
        }

        if entities.isEmpty, !title.isEmpty, let inferred = inferPersonFromTitle(title, organisations: organisations) {
            entities.append(inferred)
        }

        return Array(Set(entities.map { $0.normalizedName + "|" + ($0.context ?? "") })).prefix(8).compactMap { key in
            entities.first { ($0.normalizedName + "|" + ($0.context ?? "")) == key }
        }
    }

    private func inferPersonFromTitle(_ title: String, organisations: [String]) -> MemoryEntity? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = title
        var found: MemoryEntity?
        tagger.enumerateTags(in: title.startIndex..<title.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .joinNames]) { tag, range in
            guard tag == .personalName else { return true }
            let name = String(title[range])
            guard name.split(separator: " ").count >= 2 else { return true }
            let context = organisations.prefix(2).joined(separator: "|")
            found = MemoryEntity(type: "person", name: name, context: context.isEmpty ? title : context)
            return false
        }
        return found
    }

    // MARK: - Helpers

    private func inferType(from processed: ProcessedObservation, text: String) -> MemoryType {
        if processed.url != nil {
            if text.contains("func ") || text.contains("import ") || text.contains("class ") || text.contains("def ") {
                return .code
            }
            return .research
        }
        if text.contains("TODO") || text.contains("task") { return .task }
        return .document
    }

    private func cleanTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: " - Google Chrome", with: "")
            .replacingOccurrences(of: " - Safari", with: "")
            .replacingOccurrences(of: " - Firefox", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isNoiseLine($0) }
            .reduce(into: [String]()) { lines, line in
                if lines.last?.lowercased() != line.lowercased() {
                    lines.append(line)
                }
            }
            .joined(separator: "\n")
    }

    private func isNoiseLine(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.count >= 8 else { return true }

        let noisePatterns = [
            "skip to main content", "skip to content", "skip navigation",
            "accept cookies", "cookie policy", "privacy policy",
            "sign in", "log in", "sign up", "subscribe", "newsletter",
            "menu", "close dialog", "toggle navigation", "back to top",
            "loading...", "please wait", "enable javascript",
            "©", "all rights reserved", "terms of service", "terms of use"
        ]
        if noisePatterns.contains(where: { lower.contains($0) }) { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.split(separator: " ").count <= 2 { return true }

        let alphaRatio = Double(lower.filter { $0.isLetter }.count) / Double(max(lower.count, 1))
        return alphaRatio < 0.45
    }

    private static let stopWords: Set<String> = [
        "about", "after", "also", "always", "and", "any", "are", "been", "before",
        "being", "both", "but", "can", "could", "did", "does", "doing", "done",
        "each", "for", "from", "had", "has", "have", "here", "home", "how", "into",
        "just", "like", "more", "most", "not", "now", "off", "only", "other", "our",
        "out", "over", "same", "she", "should", "some", "such", "than", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "through", "under", "until", "very", "was", "were", "what", "when", "where",
        "which", "while", "who", "will", "with", "would", "you", "your", "skip",
        "main", "content", "page", "click", "view", "read", "show", "hide"
    ]
}
