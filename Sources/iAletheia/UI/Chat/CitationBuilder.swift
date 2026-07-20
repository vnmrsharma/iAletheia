import Foundation

struct ChatCitation: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case memory, web }

    let id: Int
    let title: String
    let url: URL?
    let subtitle: String
    let kind: Kind
}

enum CitationBuilder {
    /// Build citations only for `[N]` markers actually present in the answer text.
    /// For web-search responses without inline markers, include all web source citations.
    static func from(response: AssistantResponse) -> [ChatCitation] {
        let all = allCitations(from: response)
        let referenced = referencedCitationIDs(in: response.answer)
        if !referenced.isEmpty {
            return all.filter { referenced.contains($0.id) }
        }
        if response.usedWebSearch {
            return all.filter { $0.kind == .web }
        }
        return []
    }

    static func referencedCitationIDs(in text: String) -> Set<Int> {
        let pattern = #"\[(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids = Set<Int>()
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let idRange = Range(match.range(at: 1), in: text),
                  let id = Int(text[idRange]) else { return }
            ids.insert(id)
        }
        return ids
    }

    static func filterSources(
        answer: String,
        memorySources: [ResponseSource],
        webSources: [WebSearchResult]
    ) -> (sources: [ResponseSource], webSources: [WebSearchResult]) {
        let referenced = referencedCitationIDs(in: answer)
        guard !referenced.isEmpty else { return ([], []) }

        let memory = memorySources.enumerated().compactMap { index, source -> ResponseSource? in
            referenced.contains(index + 1) ? source : nil
        }
        let offset = memorySources.count
        let web = webSources.enumerated().compactMap { index, result -> WebSearchResult? in
            referenced.contains(offset + index + 1) ? result : nil
        }
        return (memory, web)
    }

    private static func allCitations(from response: AssistantResponse) -> [ChatCitation] {
        var citations: [ChatCitation] = []
        var index = 1

        for source in response.sources {
            citations.append(ChatCitation(
                id: index,
                title: source.title,
                url: source.url.flatMap { URL(string: $0) },
                subtitle: "\(source.applicationName) · \(source.observedAt.formatted(date: .abbreviated, time: .shortened))",
                kind: .memory
            ))
            index += 1
        }

        for web in response.webSources {
            citations.append(ChatCitation(
                id: index,
                title: web.title,
                url: URL(string: web.url),
                subtitle: "Web",
                kind: .web
            ))
            index += 1
        }

        return citations
    }

    static func linkifiedMarkdown(text: String, citations: [ChatCitation]) -> String {
        var result = text
        for citation in citations.sorted(by: { $0.id > $1.id }) {
            let marker = "[\(citation.id)]"
            if let url = citation.url {
                let mdLink = "[\(citation.id)](\(url.absoluteString))"
                result = result.replacingOccurrences(of: marker, with: mdLink)
            }
        }
        return result
    }

    static func numberedSourceBlock(sources: [ResponseSource], webResults: [WebSearchResult]) -> String {
        var lines: [String] = []
        var index = 1
        for source in sources {
            let url = source.url ?? "none"
            lines.append("[\(index)] Memory — \(source.title) (\(source.applicationName), \(url))")
            index += 1
        }
        for web in webResults {
            lines.append("[\(index)] Web — \(web.title) (\(web.url))")
            index += 1
        }
        return lines.isEmpty ? "No external sources." : lines.joined(separator: "\n")
    }

    static let citationInstruction = """
    Only include inline citations like [1], [2] when you actually use information from that numbered source.
    Place citations immediately after the specific claim they support.
    Do NOT cite sources for general knowledge, greetings, or simple math.
    Do not invent citation numbers.
    """
}
