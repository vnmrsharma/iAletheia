import Foundation

enum AnswerRoute: String, Codable, Equatable {
    case direct
    case memory
    case web
    case memoryAndWeb = "memory_and_web"
    case liveScreen = "live_screen"

    var label: String {
        switch self {
        case .direct: return "direct"
        case .memory: return "memory"
        case .web: return "web"
        case .memoryAndWeb: return "memory_and_web"
        case .liveScreen: return "live_screen"
        }
    }

    var statusText: String {
        switch self {
        case .direct: return "Thinking…"
        case .memory: return "Searching your memories…"
        case .web: return "Searching the web…"
        case .memoryAndWeb: return "Searching memories & web…"
        case .liveScreen: return "Reading your screen…"
        }
    }
}

struct RouteDecision: Equatable {
    let route: AnswerRoute
    let searchQuery: String?
    let confidence: Double
    let reason: String
}

/// Classifies queries into: direct LLM answer, personal memory, web search, or hybrid.
final class QueryRouter {
    private let qwenClient: QwenClient

    init(qwenClient: QwenClient) {
        self.qwenClient = qwenClient
    }

    func classify(query: String, webSearchEnabled: Bool) async throws -> RouteDecision {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RouteDecision(route: .direct, searchQuery: nil, confidence: 1.0, reason: "empty")
        }

        if let local = classifyLocally(query: trimmed, webSearchEnabled: webSearchEnabled) {
            return local
        }

        if qwenClient.isConfigured {
            if let llm = try await classifyWithLLM(query: trimmed, webSearchEnabled: webSearchEnabled) {
                return llm
            }
        }

        return RouteDecision(route: .direct, searchQuery: nil, confidence: 0.5, reason: "fallback_direct")
    }

    func classifyLocally(query: String, webSearchEnabled: Bool) -> RouteDecision? {
        let lower = query.lowercased()

        if Self.isLiveScreenQuery(query) {
            return RouteDecision(route: .liveScreen, searchQuery: nil, confidence: 0.99, reason: "live_screen")
        }

        if matchesGreeting(lower) {
            return RouteDecision(route: .direct, searchQuery: nil, confidence: 0.98, reason: "greeting")
        }

        if webSearchEnabled, Self.isExplicitWebSearch(query) {
            return RouteDecision(
                route: .web,
                searchQuery: Self.optimizedWebQuery(from: query),
                confidence: 0.97,
                reason: "explicit_web_search"
            )
        }

        if matchesDirectAnswer(lower) {
            return RouteDecision(route: .direct, searchQuery: nil, confidence: 0.95, reason: "model_knowledge")
        }

        if matchesPersonalRecall(lower) {
            return RouteDecision(route: .memory, searchQuery: nil, confidence: 0.92, reason: "personal_recall")
        }

        if Self.isPersonalLifeQuestion(query) {
            return RouteDecision(route: .memory, searchQuery: nil, confidence: 0.9, reason: "personal_life")
        }

        if webSearchEnabled, matchesHybridQuery(lower) {
            return RouteDecision(
                route: .memoryAndWeb,
                searchQuery: Self.optimizedWebQuery(from: query),
                confidence: 0.88,
                reason: "hybrid"
            )
        }

        if webSearchEnabled, matchesLiveWebQuery(lower) {
            return RouteDecision(
                route: .web,
                searchQuery: Self.optimizedWebQuery(from: query),
                confidence: 0.9,
                reason: "live_information"
            )
        }

        return nil
    }

    private func classifyWithLLM(query: String, webSearchEnabled: Bool) async throws -> RouteDecision? {
        let prompt = """
        Classify this user message for a personal AI assistant that has:
        1) direct — answer from the model alone (greetings, general knowledge, math, historical dates/days, definitions, coding concepts, opinions, creative writing unrelated to what's on screen)
        2) memory — answer from the user's private PAST screen history (what they previously read, worked on, saw, researched)
        3) web — needs live internet data (breaking news, today's weather, current prices, scores, releases after 2024, real-time status)
        4) memory_and_web — explicitly connects user's past activity with current external information
        5) live_screen — needs the CURRENT visible window RIGHT NOW (see my screen, what's open, draft a reply to this email, summarize this page, review this code on screen)

        CRITICAL rules:
        - Greetings ("hey", "hi", "hello") → direct. Never memory or web.
        - "Can you see my screen", typos of screen, "what's on my screen", "draft a reply to this email", "what should I reply here" → live_screen. Never memory.
        - Questions with here/this about replying, messaging, or what's visible → live_screen. Do not ask the user to paste.
        - Historical date/day questions ("what day was Sep 22 2021") → direct. Never web.
        - Math, definitions, explanations → direct unless user says "what did I read about X"
        - "What was I working on", "what did I read", "yesterday I" → memory
        - Personal situational/advisory about the user ("am I doing well financially", "should I worry about my account", "how is my…") → memory (use their screen history: emails, bank notices, docs)
        - Never use direct for questions about the user's personal life when memories could apply.
        - "Latest news on X", "current price", "weather today" → web (only if web enabled: \(webSearchEnabled))
        - If web disabled, never return web or memory_and_web — use direct, memory, or live_screen instead.

        Return ONLY JSON:
        {
          "route": "direct" | "memory" | "web" | "memory_and_web" | "live_screen",
          "search_query": "optimized web query or null",
          "confidence": 0.0,
          "reason": "short reason"
        }

        User message: \(query)
        """

        let content = try await qwenClient.chatCompletion(
            prompt: prompt,
            system: "You are a query router. Return valid JSON only. Prefer live_screen whenever the user refers to what is visible now. Be conservative with web — most questions do NOT need it."
        )

        guard let data = extractJSON(from: content),
              let payload = try? JSONDecoder().decode(RoutePayload.self, from: data) else {
            return nil
        }

        var route = payload.route
        if !webSearchEnabled && (route == .web || route == .memoryAndWeb) {
            route = route == .memoryAndWeb ? .memory : .direct
        }

        return RouteDecision(
            route: route,
            searchQuery: payload.searchQuery,
            confidence: payload.confidence,
            reason: payload.reason
        )
    }

    private func matchesGreeting(_ lower: String) -> Bool {
        if Self.isLiveScreenQuery(lower) { return false }
        let stripped = lower.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let greetings = [
            "hey", "hi", "hello", "hiya", "yo", "sup", "good morning", "good afternoon",
            "good evening", "thanks", "thank you", "thx", "ok", "okay", "cool", "nice"
        ]
        if greetings.contains(stripped) { return true }
        if stripped.count <= 12 && !lower.contains("?") && !matchesPersonalRecall(lower) {
            let words = stripped.split(separator: " ")
            if words.count <= 2, greetings.contains(where: { stripped.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    private func matchesDirectAnswer(_ lower: String) -> Bool {
        if Self.isLiveScreenQuery(lower) || Self.isOnScreenActionQuery(lower) { return false }
        if matchesHistoricalDateQuery(lower) { return true }
        if matchesSimpleMath(lower) { return true }

        let directSignals = [
            "explain ", "define ", "what does ", "how does ", "difference between",
            "translate ", "calculate ", "solve ",
            "in python", "in swift", "in javascript", "code for", "algorithm for"
        ]
        if directSignals.contains(where: { lower.contains($0) }) && !matchesPersonalRecall(lower) {
            return true
        }

        // Generic "write a …" is direct only when not about the user's current email/screen.
        if (lower.contains("write a ") || lower.contains("help me write"))
            && !lower.contains("email") && !lower.contains("reply") && !lower.contains("this")
            && !matchesPersonalRecall(lower) {
            return true
        }

        if lower.contains("day of the week") || lower.contains("what day was") || lower.contains("which day was") {
            return true
        }

        let mathPattern = #"^\s*[\d\s+\-*/().]+\s*=\?\s*$"#
        if lower.range(of: mathPattern, options: .regularExpression) != nil { return true }

        return false
    }

    private func matchesSimpleMath(_ lower: String) -> Bool {
        if matchesPersonalRecall(lower) || Self.isPersonalLifeQuestion(lower) { return false }

        let patterns = [
            #"what is\s+[\d\s+\-*/().]+"#,
            #"what's\s+[\d\s+\-*/().]+"#,
            #"how much is\s+[\d\s+\-*/().]+"#,
            #"^\s*[\d\s+\-*/()]+\s*\?\s*$"#,
            #"^(what is|what's|calculate|compute)\s+[\d]+\s*[\+\-\*/]\s*[\d]+\s*\??$"#
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    private func matchesHistoricalDateQuery(_ lower: String) -> Bool {
        let datePatterns = [
            #"what day (?:was|is|on|for)\s"#, #"day of the week"#, #"which day"#, #"what date"#
        ]
        let hasDatePattern = datePatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
        let hasYearOrDate = lower.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil
            || lower.range(of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#, options: .regularExpression) != nil
            || lower.range(of: #"\b\d{1,2}(st|nd|rd|th)?\b"#, options: .regularExpression) != nil

        if hasDatePattern && hasYearOrDate { return true }

        if lower.contains("day on") && hasYearOrDate { return true }
        return false
    }

    private func matchesPersonalRecall(_ lower: String) -> Bool {
        // Never treat live-screen / on-screen action asks as historical memory.
        if Self.isLiveScreenQuery(lower) || Self.isOnScreenActionQuery(lower) { return false }

        let signals = [
            "what did i", "what was i", "what have i",
            "did i read", "did i work", "did i research", "did i look", "did i search",
            "i was working", "i was reading", "i was researching", "i was searching", "i was looking",
            "searching about", "forgot what", "i forgot",
            "what i read", "what i worked",
            "what i researched", "what i saw", "what i opened", "what i viewed",
            "remember when i", "remind me what", "from my memories", "from my memory",
            "in my history", "find what i", "recall what",
            "last time i", "when did i", "where did i read", "summarize what i",
            "everything i read", "projects i", "pages i", "docs i",
            "my projects", "my recent", "summarize my", "summary of my",
            "recent work", "recent projects", "what projects",
            "this morning i", "earlier today i", "before the meeting",
            "screen history", "from earlier", "previously i"
        ]
        if signals.contains(where: { lower.contains($0) }) { return true }

        let temporalPersonal = [
            "yesterday", "last week", "last night", "this morning", "earlier today", "today i"
        ]
        if temporalPersonal.contains(where: { lower.contains($0) }) {
            let personalNouns = ["read", "work", "research", "look", "open", "watch", "write", "browse", "study", "search"]
            if personalNouns.contains(where: { lower.contains($0) }) { return true }
            if lower.contains("what") || lower.contains("summarize") || lower.contains("remember") || lower.contains("forgot") { return true }
        }

        return false
    }

    private func matchesLiveWebQuery(_ lower: String) -> Bool {
        if matchesPersonalRecall(lower) { return false }
        if matchesHistoricalDateQuery(lower) { return false }

        let liveSignals = [
            "latest ", "breaking ", "right now", "as of today", "currently ",
            "today's ", "this week's news", "news today", "weather today",
            "weather in", "weather for", "forecast for", "stock price",
            "share price", "live score", "who won", "release date for",
            "when is .* coming out", "is .* down", "outage", "trending now"
        ]
        for signal in liveSignals {
            if signal.contains(".*") {
                if lower.range(of: signal, options: .regularExpression) != nil { return true }
            } else if lower.contains(signal) {
                return true
            }
        }

        if lower.contains("search the web") || lower.contains("look up online") || lower.contains("google ") {
            return true
        }

        if lower.contains("top ") && (lower.contains("results") || lower.contains("result")) {
            return true
        }

        if lower.contains("search") && (lower.contains("web") || lower.contains("online") || lower.contains("internet")) {
            return true
        }

        let currentYear = Calendar.current.component(.year, from: Date())
        if lower.contains("\(currentYear)") && (lower.contains("news") || lower.contains("update") || lower.contains("latest")) {
            return true
        }

        return false
    }

    private func matchesHybridQuery(_ lower: String) -> Bool {
        let hybridSignals = [
            "compare what i", "based on what i read", "based on my research",
            "connect what i", "what i read vs", "what i read versus",
            "my notes and current", "my research and latest", "what i worked on and",
            "combine my", "relate what i"
        ]
        return hybridSignals.contains(where: { lower.contains($0) })
    }

    static func isExplicitWebSearch(_ query: String) -> Bool {
        let lower = query.lowercased()
        let signals = [
            "search web", "search the web", "web search", "search online",
            "look up online", "google me", "google my name", "search for my name",
            "search with my name", "find me online", "top 10 results", "top ten results",
            "what appears when you search", "search results for"
        ]
        if signals.contains(where: { lower.contains($0) }) { return true }
        if lower.contains("search") && lower.contains("web") { return true }
        if lower.contains("top ") && lower.contains("result") { return true }
        return false
    }

    /// Questions about the user's own life/situation that should use screen memories.
    static func isPersonalLifeQuestion(_ query: String) -> Bool {
        let lower = query.lowercased()
        let signals = [
            "am i doing", "do i ", "should i ", "how am i", "am i okay", "am i good",
            "my financial", "my finance", "my money", "my bank", "my account", "my salary",
            "my career", "my health", "my situation", "about my ", "doing well",
            "worried about my", "think i am", "think i'm", "concerned about my",
            "any issues with my", "anything wrong with my", "did i get", "have i received"
        ]
        if signals.contains(where: { lower.contains($0) }) { return true }

        let personalDomains = ["financial", "finance", "money", "bank", "account", "charge", "email", "career", "job", "health"]
        if personalDomains.contains(where: { lower.contains($0) }) {
            if lower.contains(" i ") || lower.contains(" my ") || lower.hasPrefix("i ") { return true }
        }
        return false
    }

    /// User wants to know what's on their screen right now — not historical memory.
    static func isLiveScreenQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let normalized = lower
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        // Past-tense / history questions belong to memory, not live capture.
        let pastSignals = [
            "what did i", "what was i", "what have i", "did i see", "did i look",
            "yesterday", "last week", "last night", "earlier today", "this morning i",
            "from my memory", "from my memories", "in my history", "screen history"
        ]
        if pastSignals.contains(where: { normalized.contains($0) })
            && !normalized.contains("right now") && !normalized.contains("currently") {
            return false
        }

        let signals = [
            "what can you see", "what do you see", "what are you seeing",
            "what's on my screen", "what is on my screen", "on my screen now",
            "my screen now", "screen right now", "see on my screen",
            "see my screen", "see the screen", "look at my screen", "look at the screen",
            "can you see my", "can you see this", "can u see my", "can u see this",
            "do you see my", "do you see this", "are you able to see",
            "what am i looking at", "what am i viewing", "what am i reading",
            "what's open right now", "what is open right now",
            "read my screen", "active screen", "current screen",
            "what's on screen", "what is on screen",
            "what window", "what app am i", "which app am i",
            "what file am i", "what am i working on right now",
            "what do i have open", "what's in front of me",
            "describe my screen", "describe this screen", "describe what i'm looking"
        ]
        if signals.contains(where: { normalized.contains($0) }) { return true }

        // Fuzzy "screen" (typos: scrren, scren, screeen, scren)
        let mentionsScreen = normalized.range(
            of: #"\bscr+e+n\b"#,
            options: .regularExpression
        ) != nil
        if mentionsScreen {
            let liveVerbs = ["see", "look", "read", "show", "describe", "what's", "what is", "whats"]
            if liveVerbs.contains(where: { normalized.contains($0) }) { return true }
            if normalized.contains("now") || normalized.contains("currently") || normalized.contains("right now") {
                return true
            }
        }

        // "can you see …" with a typo'd screen word nearby
        if (normalized.contains("can you see") || normalized.contains("can u see") || normalized.contains("do you see"))
            && (mentionsScreen || normalized.contains("this") || normalized.contains("email") || normalized.contains("page")) {
            return true
        }

        return isOnScreenActionQuery(query)
    }

    /// Actions that require the current window contents (draft reply, summarize this email, etc.).
    static func isOnScreenActionQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actionSignals = [
            "draft a reply", "draft reply", "write a reply", "write reply",
            "reply to this", "reply for this", "respond to this",
            "draft an email", "draft email", "compose a reply",
            "help me reply", "help me respond", "help me answer this",
            "summarize this email", "summarise this email", "summarize this message",
            "what does this email", "what's this email", "what is this email",
            "who is this email", "from this email", "about this email",
            "this email", "this message", "this inbox", "this mail",
            "based on this email", "based on the email",
            "copy paste", "copy-paste", "so i can send", "so i can paste",
            "what's on this page", "what is on this page", "summarize this page",
            "summarize this", "summarise this", "explain this page",
            "what am i reading", "read this email", "read this message",
            // Deictic reply / messaging help — must use live screen without "look at my screen"
            "what should i reply", "what should i say", "what do i reply", "what do i say",
            "how should i reply", "how should i respond", "how do i reply", "how do i respond",
            "what to reply", "what to say", "what can i reply", "what can i say",
            "suggest a reply", "suggest a response", "good reply", "good response",
            "reply here", "respond here", "say here", "answer here",
            "should i reply", "write a response", "write back",
            "what should i respond", "help me write back",
            "answer this message", "answer this chat", "reply to him", "reply to her",
            "what does this say", "what's this about", "what is this about"
        ]
        if actionSignals.contains(where: { lower.contains($0) }) { return true }

        // "draft/write … reply/email/response"
        let wantsDraft = lower.contains("draft") || lower.contains("write a") || lower.contains("compose")
        let aboutMail = lower.contains("email") || lower.contains("reply") || lower.contains("response") || lower.contains("message")
        if wantsDraft && aboutMail { return true }

        // "here" / "this" + communicative intent (e.g. "what should i reply here")
        let deictic = lower.contains(" here") || lower.hasSuffix(" here") || lower.contains("here?")
            || lower.contains(" this") || lower.contains("this?")
            || lower.contains("that message") || lower.contains("this chat")
            || lower.contains("this dm") || lower.contains("this thread")
            || lower.contains("this conversation") || lower.contains("this linkedin")
        let communicative = lower.contains("reply") || lower.contains("respond") || lower.contains("response")
            || lower.contains("answer")
            || (lower.contains("say") && (lower.contains("what") || lower.contains("should") || lower.contains("how")))
        if deictic && communicative { return true }

        return false
    }

    static func optimizedWebQuery(from query: String) -> String {
        var q = query
            .replacingOccurrences(of: #"(?i)\b(can you|could you|please|tell me|let me know)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count > 120 { q = String(q.prefix(120)) }
        return q.isEmpty ? query : q
    }

    private func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return Data(text[start...end].utf8)
    }
}

private struct RoutePayload: Decodable {
    let route: AnswerRoute
    let searchQuery: String?
    let confidence: Double
    let reason: String

    enum CodingKeys: String, CodingKey {
        case route
        case searchQuery = "search_query"
        case confidence
        case reason
    }
}
