import Foundation

struct WebSearchResult: Codable, Equatable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let snippet: String
}

final class WebSearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool { true }

    func search(query: String, limit: Int = 5) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let apiKey = EnvLoader.value(for: "TAVILY_API_KEY"), !apiKey.isEmpty {
            if let results = try? await searchTavily(query: trimmed, apiKey: apiKey, limit: limit), !results.isEmpty {
                return results
            }
        }

        if let apiKey = EnvLoader.value(for: "BRAVE_SEARCH_API_KEY"), !apiKey.isEmpty {
            if let results = try? await searchBrave(query: trimmed, apiKey: apiKey, limit: limit), !results.isEmpty {
                return results
            }
        }

        return try await searchDuckDuckGo(query: trimmed, limit: limit)
    }

    private func searchTavily(query: String, apiKey: String, limit: Int) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "query": query,
            "max_results": limit,
            "include_answer": false
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.prefix(limit).compactMap { item in
            guard let title = item["title"] as? String,
                  let link = item["url"] as? String else { return nil }
            let snippet = (item["content"] as? String) ?? ""
            return WebSearchResult(title: title, url: link, snippet: String(snippet.prefix(280)))
        }
    }

    private func searchBrave(query: String, apiKey: String, limit: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit))
        ]
        var request = URLRequest(url: components.url!)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "X-Subscription-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else { return [] }
        return results.prefix(limit).compactMap { item in
            guard let title = item["title"] as? String,
                  let link = item["url"] as? String else { return nil }
            let snippet = (item["description"] as? String) ?? ""
            return WebSearchResult(title: title, url: link, snippet: String(snippet.prefix(280)))
        }
    }

    private func searchDuckDuckGo(query: String, limit: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WebSearchError.requestFailed
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let parsed = parseDuckDuckGoHTML(html, limit: limit)
        if parsed.isEmpty {
            return try await searchDuckDuckGoInstant(query: query, limit: limit)
        }
        return parsed
    }

    private func searchDuckDuckGoInstant(query: String, limit: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1")
        ]
        let request = URLRequest(url: components.url!)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var results: [WebSearchResult] = []
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty,
           let heading = json["Heading"] as? String,
           let url = json["AbstractURL"] as? String, !url.isEmpty {
            results.append(WebSearchResult(title: heading, url: url, snippet: abstract))
        }

        if let topics = json["RelatedTopics"] as? [[String: Any]] {
            for topic in topics {
                if let text = topic["Text"] as? String,
                   let url = topic["FirstURL"] as? String {
                    let title = text.components(separatedBy: " - ").first ?? text
                    results.append(WebSearchResult(title: title, url: url, snippet: text))
                }
                if results.count >= limit { break }
            }
        }
        return Array(results.prefix(limit))
    }

    private func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        let linkPattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</(?:a|td|span|div)>"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let linkMatches = linkRegex.matches(in: html, options: [], range: range)
        let snippetMatches = snippetRegex.matches(in: html, options: [], range: range)

        for (index, match) in linkMatches.prefix(limit).enumerated() {
            guard match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var url = String(html[urlRange])
            if url.hasPrefix("//") { url = "https:" + url }

            let title = stripHTML(String(html[titleRange]))
            var snippet = ""
            if index < snippetMatches.count {
                let snippetMatch = snippetMatches[index]
                if snippetMatch.numberOfRanges >= 2,
                   let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                    snippet = stripHTML(String(html[snippetRange]))
                }
            }
            guard !title.isEmpty, url.hasPrefix("http") else { continue }
            results.append(WebSearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WebSearchError: Error, LocalizedError {
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Web search request failed."
        }
    }
}
