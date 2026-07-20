import Foundation
import Security

final class KeychainService {
    private let service = "com.ialetheia.app"

    func save(key: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}

struct QwenConfiguration {
    var apiKey: String?
    var baseURL: String
    var textModel: String
    var webSearchModel: String
    var visionModel: String
    var embeddingModel: String
    var rerankModel: String

    var dashScopeAPIRoot: String {
        if baseURL.contains("dashscope-intl.aliyuncs.com") {
            return "https://dashscope-intl.aliyuncs.com/api/v1"
        }
        if baseURL.contains("dashscope.aliyuncs.com") {
            return "https://dashscope.aliyuncs.com/api/v1"
        }
        return "https://dashscope-intl.aliyuncs.com/api/v1"
    }

    var responsesAPIURL: String {
        if baseURL.hasSuffix("/v1") {
            return baseURL + "/responses"
        }
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/responses"
    }

    var supportsResponsesWebSearch: Bool {
        let model = webSearchModel.lowercased()
        return model.contains("qwen3")
    }

    static var current: QwenConfiguration {
        EnvLoader.loadIfNeeded()
        let keychain = KeychainService()
        let textModel = EnvLoader.value(for: "QWEN_TEXT_MODEL") ?? "qwen-plus"
        return QwenConfiguration(
            apiKey: keychain.read(key: "QWEN_API_KEY") ?? EnvLoader.value(for: "QWEN_API_KEY"),
            baseURL: EnvLoader.value(for: "QWEN_BASE_URL") ?? "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            textModel: textModel,
            webSearchModel: EnvLoader.value(for: "QWEN_WEB_SEARCH_MODEL") ?? textModel,
            visionModel: EnvLoader.value(for: "QWEN_VISION_MODEL") ?? "qwen-vl-plus",
            embeddingModel: EnvLoader.value(for: "QWEN_EMBEDDING_MODEL") ?? "text-embedding-v3",
            rerankModel: EnvLoader.value(for: "QWEN_RERANK_MODEL") ?? "gte-rerank"
        )
    }
}

final class QwenClient: QwenService {
    private let keychainService: KeychainService
    private let session: URLSession

    init(keychainService: KeychainService, session: URLSession = .shared) {
        self.keychainService = keychainService
        self.session = session
    }

    var isConfigured: Bool {
        QwenConfiguration.current.apiKey?.isEmpty == false
    }

    func saveAPIKey(_ key: String) throws {
        try keychainService.save(key: "QWEN_API_KEY", value: key)
    }

    func extractMemories(from observation: ProcessedObservation) async throws -> [MemoryCandidate] {
        guard isConfigured else { return [] }

        let textSample = String(observation.redactedText.prefix(8000))
        guard textSample.count >= 40 else { return [] }

        let system = """
        You summarize what a Mac user is currently viewing so a personal memory agent can recall it later.
        Write useful, factual summaries — not raw OCR dumps.
        Ignore navigation chrome, cookie banners, and boilerplate.
        Return only valid JSON.
        """
        let prompt = """
        Application: \(observation.applicationName)
        Window/page title: \(observation.title ?? "Unknown")
        URL: \(observation.url ?? "none")

        Visible text from the screen:
        \(textSample)

        Return JSON:
        {
          "summary": "2-4 sentences: what this page/document is, what the user is likely working on, and the most important facts worth recalling later",
          "topics": ["3-6 meaningful topics, not stop words"],
          "keywords": ["5-10 useful keywords"],
          "entities": [{"name": "string", "type": "person|organisation|place|entity", "context": "short disambiguating context e.g. org or role"}],
          "memory_type": "research|webpage|document|code|project|task|person",
          "importance": 0.0
        }
        """

        let content = try await chatCompletion(prompt: prompt, system: system)
        guard let data = extractJSON(from: content),
              let payload = try? JSONDecoder().decode(QwenMemoryExtractionPayload.self, from: data),
              !payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let type = MemoryType(rawValue: payload.memoryType) ?? (observation.url == nil ? .document : .research)
        let utility = min(1.0, max(0.3, payload.importance))
        let entities = (payload.entities ?? []).map {
            MemoryEntity(type: $0.type, name: $0.name, context: $0.context)
        }

        return [MemoryCandidate(
            id: UUID(),
            type: type == .research && !entities.contains(where: { $0.type == "person" }) ? type : (entities.contains(where: { $0.type == "person" }) ? .person : type),
            title: observation.title ?? observation.applicationName,
            content: observation.redactedText,
            summary: payload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            topics: Array(payload.topics.prefix(8)),
            keywords: Array(payload.keywords.prefix(10)),
            entities: entities,
            suggestedImportance: utility,
            suggestedConfidence: 0.9,
            suggestedExpiry: nil,
            sourceURL: observation.url,
            sourceTitle: observation.title,
            futureUtility: utility,
            actionability: observation.url == nil ? 0.45 : 0.8,
            explicitness: 0.65,
            transience: observation.url == nil ? 0.3 : 0.15
        )]
    }

    func interpretQuery(_ query: String, currentDate: Date, timezone: TimeZone) async throws -> SearchIntent {
        let prompt = """
        Convert this memory query into JSON with keys:
        intent, semantic_query, keywords, related_concepts, time_range, source_types, requested_output.
        Query: \(query)
        Current date: \(ISO8601DateFormatter().string(from: currentDate))
        Timezone: \(timezone.identifier)
        """
        let content = try await chatCompletion(prompt: prompt, system: "Return only valid JSON.")
        return (try? JSONDecoder().decode(SearchIntent.self, from: Data(content.utf8))) ?? SearchIntent(
            intent: "recall",
            semanticQuery: query,
            keywords: query.split(separator: " ").map(String.init),
            relatedConcepts: [],
            timeRange: QueryInterpreter().parseRelativeTime(query: query, now: currentDate),
            sourceTypes: ["research", "webpage"],
            requestedOutput: ["summary", "links"]
        )
    }

    func generateEmbedding(for text: String) async throws -> [Float] {
        []
    }

    func rerank(query: String, memories: [Memory]) async throws -> [RankedMemory] {
        memories.map { RankedMemory(memory: $0, score: 0.5) }
    }

    func generateResponse(query: String, memories: [Memory]) async throws -> AssistantResponse {
        let ranked = memories.map { RankedMemory(memory: $0, score: 0.5) }
        return try await generateMemoryResponse(query: query, rankedMemories: ranked)
    }

    func generateDirectResponse(
        query: String,
        personality: String = "",
        history: [ConversationTurn] = []
    ) async throws -> AssistantResponse {
        let system = """
        You are iAletheia, a warm and capable personal AI assistant.
        Answer directly, accurately, and concisely.
        Use the conversation history when the user refers to earlier messages (this, that, the code, errors, etc.).
        For greetings: be friendly and brief. Do NOT invent details about the user's work or screen unless history or screen context provides them.
        For factual questions (dates, math, definitions): answer precisely from your knowledge.
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        let answer = try await chatCompletionFast(prompt: query, system: system, maxTokens: 800, history: history)
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(answer),
            sources: [],
            usedMemoryIDs: [],
            confidence: 0.85,
            ambiguityNotice: nil,
            route: .direct
        )
    }

    func generateLiveScreenResponse(
        query: String,
        snapshot: LiveScreenSnapshot,
        personality: String = "",
        history: [ConversationTurn] = []
    ) async throws -> AssistantResponse {
        let system = """
        You are iAletheia with live access to the user's Mac screen RIGHT NOW.
        Use ONLY the live snapshot below — never invent past memories or unrelated history.

        When answering "what can you see" / screen questions:
        1) Say which app is active and the window/tab title (and URL if present).
        2) Summarize what the visible content is about with concrete details from the snapshot.
        3) If code is visible: briefly explain what the code is doing.
        4) If an email/message is visible: name the sender, subject/topic, and key asks in the message.
        5) Never say you only have screen history. Never invent Cursor/Safari/other apps that are not in this snapshot.
        6) Never say OCR failed or that you cannot see the screen unless the snapshot truly has no app/window info.
        7) Be specific and concise.
        8) Do NOT invent spelling typos, misspellings, or "visible errors" in comments/strings unless the user explicitly asks you to review for bugs/typos AND the word is clearly wrong in a coherent way (not OCR garbage like random letter soup).
        9) OCR noise is common — never claim a word is misspelled based on a garbled OCR fragment.
        10) Trust the window title and URL as the active tab. If body text conflicts (wrong site), follow the title/URL and any matching content — do not claim the user is on the mismatched site.

        When the user explicitly asks to review code / find errors / bugs:
        - Focus on real logic, API, type, and compile issues.
        - Only mention a spelling typo if it is unambiguous in readable text (not OCR noise).
        - If unsure, say the code looks fine rather than inventing problems.

        When the user asks to draft a reply / respond to an email or message:
        1) Read the visible email carefully (sender, questions, tone).
        2) Write a polished reply they can copy-paste and send.
        3) Put the reply in a clear block after a one-line intro like: Here is a draft you can copy and send.
        4) Match a professional, friendly tone unless the email suggests otherwise.
        5) Answer the sender's questions when the user's context is unknown — write sensible placeholders in [brackets] for personal details they must fill in.
        6) Do not add markdown bold/italic or asterisks.

        Use conversation history for follow-ups like "is there any error in this?" — "this" means the screen/content just discussed.
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        let prompt = """
        User question: \(query)

        LIVE SCREEN SNAPSHOT:
        \(snapshot.contextBlock())

        Answer based on this snapshot and the conversation history. Describe what is actually there. Do not invent typos or unrelated apps. If they asked for a draft reply, produce a ready-to-send draft from the visible email.
        """
        let answer = try await chatCompletionFast(prompt: prompt, system: system, maxTokens: 1100, history: history)
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(answer),
            sources: [
                ResponseSource(
                    title: snapshot.windowTitle ?? snapshot.applicationName,
                    url: snapshot.url,
                    observedAt: snapshot.capturedAt,
                    applicationName: snapshot.applicationName
                )
            ],
            usedMemoryIDs: [],
            confidence: 0.92,
            ambiguityNotice: nil,
            usedWebSearch: false,
            route: .liveScreen
        )
    }

    func generateSessionAwareResponse(
        query: String,
        history: [ConversationTurn],
        screenContext: String?,
        personality: String = ""
    ) async throws -> AssistantResponse {
        let system = """
        You are iAletheia continuing an ongoing chat session with live screen awareness.
        Resolve pronouns like this/that/it using the conversation history and the screen context.
        If the user asks about errors in "this", review the code/content from history or the screen context — focus on real logic/API issues. Do not invent spelling typos from OCR noise.
        If they ask to draft a reply to an email/message on screen, write a polished copy-paste ready reply from the screen context.
        Be specific and helpful. Do not ask them to paste content if context is already available.
        Never invent unrelated past apps, memories, or typos that are not clearly present.
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        var prompt = "User question: \(query)\n"
        if let screenContext, !screenContext.isEmpty {
            prompt += "\nCURRENT/RECENT SCREEN CONTEXT:\n\(screenContext)\n"
        }
        prompt += "\nAnswer using the conversation history and any screen context above."
        let answer = try await chatCompletionFast(prompt: prompt, system: system, maxTokens: 1100, history: history)
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(answer),
            sources: [],
            usedMemoryIDs: [],
            confidence: 0.88,
            ambiguityNotice: nil,
            usedWebSearch: false,
            route: .direct
        )
    }

    static func localLiveScreenAnswer(query: String, snapshot: LiveScreenSnapshot) -> AssistantResponse {
        var parts: [String] = []
        parts.append("Right now you're in \(snapshot.applicationName)")
        if let title = snapshot.windowTitle, !title.isEmpty {
            parts.append("viewing \"\(title)\"")
        }
        if let url = snapshot.url, !url.isEmpty {
            parts.append("(\(url))")
        }
        let excerpt = snapshot.visibleText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 20 }
            .prefix(3)
            .joined(separator: " ")
        if !excerpt.isEmpty {
            parts.append("Visible content includes: \(String(excerpt.prefix(320)))")
        }
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(parts.joined(separator: ". ") + "."),
            sources: [
                ResponseSource(
                    title: snapshot.windowTitle ?? snapshot.applicationName,
                    url: snapshot.url,
                    observedAt: snapshot.capturedAt,
                    applicationName: snapshot.applicationName
                )
            ],
            usedMemoryIDs: [],
            confidence: 0.75,
            ambiguityNotice: nil,
            usedWebSearch: false,
            route: .liveScreen
        )
    }

    func generateMemoryResponse(query: String, rankedMemories: [RankedMemory], personality: String = "") async throws -> AssistantResponse {
        let memories = rankedMemories.map(\.memory)
        guard !memories.isEmpty else {
            return AssistantResponse(
                answer: "I don't have a personal memory about that yet. Keep working and browsing — I'll quietly learn from your screen.",
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.3,
                ambiguityNotice: "No relevant personal memories found.",
                route: .memory
            )
        }

        let memorySlice = Array(rankedMemories.prefix(8))
        let memoryContext = formatMemoryContext(memorySlice)
        let sourceBlock = CitationBuilder.numberedSourceBlock(sources: memorySlice.map {
            ResponseSource(
                title: $0.memory.sourceTitle ?? $0.memory.title,
                url: $0.memory.sourceURL,
                observedAt: $0.memory.lastObservedAt,
                applicationName: $0.memory.sourceApplication
            )
        }, webResults: [])
        let system = """
        You are iAletheia, a personal memory assistant with access to the user's private screen history.
        Answer using the memories below — emails, bank notices, documents, pages, and apps they used.
        For advisory questions (e.g. "am I doing well financially?"), ground your answer in specific evidence from their memories.
        If a memory shows a bank charge, fee notice, email alert, or financial warning, mention it explicitly with an inline citation.
        Do NOT claim you lack access to the user's personal data — you have their screen memories below.
        Be specific — cite app names, page titles, and what the user saw.
        Never invent URLs or details not in the memories.
        \(CitationBuilder.citationInstruction)
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        let prompt = """
        User query: \(query)

        Numbered sources:
        \(sourceBlock)

        Personal memories (most relevant first):
        \(memoryContext)

        Respond in JSON:
        {"answer": "string", "used_memory_ids": ["uuid"], "confidence": 0.0, "ambiguity_notice": "string or null"}
        """
        return try await parseStructuredResponse(
            prompt: prompt, system: system, memories: memories, webResults: [], route: .memory
        )
    }

    func generateWebResponse(query: String, webResults: [WebSearchResult], personality: String = "") async throws -> AssistantResponse {
        if webResults.isEmpty, isConfigured {
            return try await generateWithQwenWebSearch(query: query, rankedMemories: [], personality: personality)
        }
        guard !webResults.isEmpty else {
            return AssistantResponse(
                answer: "I couldn't find useful web results for that. Try rephrasing your question.",
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.2,
                ambiguityNotice: "Web search returned no results.",
                usedWebSearch: true,
                route: .web
            )
        }

        let webSlice = Array(webResults.prefix(6))
        let webContext = formatWebContext(webSlice)
        let sourceBlock = CitationBuilder.numberedSourceBlock(sources: [], webResults: webSlice)
        let system = """
        You are iAletheia. Answer using ONLY the web search results below.
        Be concise and accurate. Do not invent information beyond the search results.
        \(CitationBuilder.citationInstruction)
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        let prompt = """
        User query: \(query)

        Numbered sources:
        \(sourceBlock)

        Web search results:
        \(webContext)

        Respond in JSON:
        {"answer": "string", "used_memory_ids": [], "confidence": 0.0, "ambiguity_notice": "string or null"}
        """
        return try await parseStructuredResponse(
            prompt: prompt, system: system, memories: [], webResults: webResults, route: .web
        )
    }

    func generateHybridResponse(
        query: String,
        rankedMemories: [RankedMemory],
        webResults: [WebSearchResult],
        personality: String = ""
    ) async throws -> AssistantResponse {
        let memories = rankedMemories.map(\.memory)
        let memorySlice = Array(rankedMemories.prefix(6))
        let webSlice = Array(webResults.prefix(6))
        let memoryContext = memories.isEmpty ? "None found." : formatMemoryContext(memorySlice)
        let webContext = webResults.isEmpty ? "None found." : formatWebContext(webSlice)
        let memorySources = memorySlice.map {
            ResponseSource(
                title: $0.memory.sourceTitle ?? $0.memory.title,
                url: $0.memory.sourceURL,
                observedAt: $0.memory.lastObservedAt,
                applicationName: $0.memory.sourceApplication
            )
        }
        let sourceBlock = CitationBuilder.numberedSourceBlock(sources: memorySources, webResults: webSlice)

        let system = """
        You are iAletheia. Combine the user's private screen memories with live web information.
        Ground personal advice in specific memory evidence (emails, bank notices, documents) with citations.
        Use web data for current external context. Do NOT claim you lack personal data when memories are provided.
        Distinguish what comes from past activity vs current web data.
        \(CitationBuilder.citationInstruction)
        \(AnswerSanitizer.plainTextStyle)

        \(personality)
        """
        let prompt = """
        User query: \(query)

        Numbered sources:
        \(sourceBlock)

        Personal memories:
        \(memoryContext)

        Web search results:
        \(webContext)

        Respond in JSON:
        {"answer": "string", "used_memory_ids": ["uuid"], "confidence": 0.0, "ambiguity_notice": "string or null"}
        """
        return try await parseStructuredResponse(
            prompt: prompt, system: system, memories: memories, webResults: webResults, route: .memoryAndWeb
        )
    }

    /// Uses Qwen DashScope native web search (`enable_search`) for live results with citations.
    func generateWithQwenWebSearch(
        query: String,
        rankedMemories: [RankedMemory] = [],
        personality: String = ""
    ) async throws -> AssistantResponse {
        let memories = rankedMemories.map(\.memory)
        let route: AnswerRoute = memories.isEmpty ? .web : .memoryAndWeb

        var system = """
        You are iAletheia, a personal AI assistant with live web search enabled.
        Use web search to answer with current, accurate information from the internet.
        When listing search results, include titles and URLs.
        \(CitationBuilder.citationInstruction)
        \(AnswerSanitizer.plainTextStyle)
        \(personality)
        """

        var userPrompt = query
        if !rankedMemories.isEmpty {
            system += """

            The user also has private screen memories below. Combine live web results with this context when helpful.
            Clearly distinguish web findings from personal memory.
            """
            let memoryContext = formatMemoryContext(rankedMemories.prefix(6))
            userPrompt = """
            \(query)

            Personal screen memories (optional context):
            \(memoryContext)
            """
        }

        let searchResult = try await performQwenWebSearch(system: system, user: userPrompt)

        let memorySources = rankedMemories.prefix(3).map {
            ResponseSource(
                title: $0.memory.sourceTitle ?? $0.memory.title,
                url: $0.memory.sourceURL,
                observedAt: $0.memory.lastObservedAt,
                applicationName: $0.memory.sourceApplication
            )
        }
        let filtered = CitationBuilder.filterSources(
            answer: searchResult.answer,
            memorySources: route == .memoryAndWeb ? memorySources : [],
            webSources: searchResult.webResults
        )
        let finalWebSources = filtered.webSources.isEmpty ? searchResult.webResults : filtered.webSources

        let citedIDs = CitationBuilder.referencedCitationIDs(in: searchResult.answer)
        let usedMemoryIDs: [UUID] = route == .memoryAndWeb
            ? rankedMemories.prefix(3).enumerated().compactMap { index, ranked in
                citedIDs.contains(index + 1) ? ranked.memory.id : nil
            }
            : []

        let cleanAnswer = AnswerSanitizer.sanitize(searchResult.answer)
        return AssistantResponse(
            answer: cleanAnswer,
            sources: filtered.sources,
            webSources: finalWebSources,
            usedMemoryIDs: usedMemoryIDs,
            confidence: finalWebSources.isEmpty ? 0.55 : 0.88,
            ambiguityNotice: finalWebSources.isEmpty && searchResult.answer.isEmpty ? "Web search returned no results." : nil,
            usedWebSearch: !finalWebSources.isEmpty || !searchResult.answer.isEmpty,
            route: route
        )
    }

    private struct QwenWebSearchOutcome {
        let answer: String
        let webResults: [WebSearchResult]
    }

    private func performQwenWebSearch(system: String, user: String) async throws -> QwenWebSearchOutcome {
        let config = QwenConfiguration.current
        var lastError: Error?

        if config.supportsResponsesWebSearch {
            do {
                let result = try await responsesAPIWebSearch(system: system, user: user)
                guard !result.answer.isEmpty else {
                    throw QwenError.requestFailed("Responses API web search returned empty content")
                }
                return result
            } catch {
                lastError = error
            }
        }

        do {
            return try await streamingCompatibleWebSearch(system: system, user: user)
        } catch {
            lastError = error
        }

        if let lastError {
            throw lastError
        }
        throw QwenError.requestFailed(
            "Web search failed for model \(config.webSearchModel). Use a Qwen3 model (e.g. qwen3.7-plus) with the Responses API web_search tool."
        )
    }

    /// Qwen3 models: Responses API with `web_search` tool (recommended for qwen3.7-plus).
    private func responsesAPIWebSearch(system: String, user: String) async throws -> QwenWebSearchOutcome {
        let config = QwenConfiguration.current
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw QwenError.missingAPIKey
        }
        guard let url = URL(string: config.responsesAPIURL) else {
            throw QwenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.webSearchModel,
            "input": user,
            "tools": [["type": "web_search"]]
        ]
        if !system.isEmpty {
            body["instructions"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QwenError.requestFailed(String(data: data, encoding: .utf8) ?? "Responses API web search failed")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenError.requestFailed("Invalid Responses API payload")
        }
        return parseResponsesAPIOutput(json)
    }

    private func parseResponsesAPIOutput(_ json: [String: Any]) -> QwenWebSearchOutcome {
        var answer = (json["output_text"] as? String) ?? ""
        var webResults: [WebSearchResult] = []

        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                let type = item["type"] as? String ?? ""
                if type == "message",
                   let content = item["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "output_text",
                           let text = block["text"] as? String, !text.isEmpty {
                            answer = text
                        }
                    }
                }
                if type == "web_search_call",
                   let action = item["action"] as? [String: Any],
                   let sources = action["sources"] as? [[String: Any]] {
                    for source in sources {
                        guard let url = source["url"] as? String else { continue }
                        webResults.append(WebSearchResult(
                            title: titleFromURL(url),
                            url: url,
                            snippet: ""
                        ))
                    }
                }
            }
        }

        return QwenWebSearchOutcome(
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            webResults: webResults
        )
    }

    /// Fallback: streaming chat completions with enable_search (requires enable_thinking: false on Qwen3).
    private func streamingCompatibleWebSearch(system: String, user: String) async throws -> QwenWebSearchOutcome {
        let config = QwenConfiguration.current
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw QwenError.missingAPIKey
        }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw QwenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": config.webSearchModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "stream": true,
            "temperature": 0.2,
            "enable_thinking": false,
            "enable_search": true,
            "search_options": [
                "search_strategy": "agent",
                "enable_source": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw QwenError.requestFailed(String(data: errorData, encoding: .utf8) ?? "Streaming web search failed")
        }

        var answer = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            answer += content
        }

        guard !answer.isEmpty else {
            throw QwenError.requestFailed("Streaming web search returned empty content")
        }
        return QwenWebSearchOutcome(answer: answer, webResults: [])
    }

    private func titleFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { return host }
        return "\(host)/\(path.prefix(48))"
    }

    private func dashScopeNativeWebSearch(system: String, user: String) async throws -> QwenWebSearchOutcome {
        let config = QwenConfiguration.current
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw QwenError.missingAPIKey
        }

        let apiRoot = config.dashScopeAPIRoot
        guard let url = URL(string: "\(apiRoot)/services/aigc/text-generation/generation") else {
            throw QwenError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.webSearchModel,
            "input": [
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ],
            "parameters": [
                "result_format": "message",
                "enable_search": true,
                "search_options": [
                    "search_strategy": "agent",
                    "enable_source": true
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QwenError.requestFailed(String(data: data, encoding: .utf8) ?? "DashScope web search failed")
        }

        return try parseDashScopeWebSearchResponse(data)
    }

    private func compatibleModeWebSearch(system: String, user: String) async throws -> QwenWebSearchOutcome {
        try await streamingCompatibleWebSearch(system: system, user: user)
    }

    private func parseDashScopeWebSearchResponse(_ data: Data) throws -> QwenWebSearchOutcome {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any] else {
            throw QwenError.requestFailed("Unexpected DashScope web search response")
        }
        return parseDashScopeOutput(output, fallbackData: data)
    }

    private func parseDashScopeOutput(_ output: [String: Any], fallbackData: Data) -> QwenWebSearchOutcome {
        var answer = ""
        if let choices = output["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            answer = content
        } else if let text = output["text"] as? String {
            answer = text
        }

        var webResults: [WebSearchResult] = []
        if let searchInfo = output["search_info"] as? [String: Any],
           let results = searchInfo["search_results"] as? [[String: Any]] {
            webResults = results.compactMap { item in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else { return nil }
                let snippet = (item["snippet"] as? String) ?? (item["content"] as? String) ?? ""
                return WebSearchResult(title: title, url: url, snippet: String(snippet.prefix(280)))
            }
        }

        if answer.isEmpty, let decoded = try? JSONDecoder().decode(QwenChatResponse.self, from: fallbackData) {
            answer = decoded.choices.first?.message.content ?? ""
        }

        return QwenWebSearchOutcome(answer: answer.trimmingCharacters(in: .whitespacesAndNewlines), webResults: webResults)
    }

    func generateAgentResponse(
        query: String,
        memories: [Memory],
        webResults: [WebSearchResult],
        plan: AgentPlan
    ) async throws -> AssistantResponse {
        let ranked = memories.map { RankedMemory(memory: $0, score: 0.5) }
        switch plan.route {
        case .direct: return try await generateDirectResponse(query: query)
        case .memory: return try await generateMemoryResponse(query: query, rankedMemories: ranked)
        case .web: return try await generateWebResponse(query: query, webResults: webResults)
        case .memoryAndWeb: return try await generateHybridResponse(query: query, rankedMemories: ranked, webResults: webResults)
        case .liveScreen:
            throw QwenError.requestFailed("Live screen responses must go through PersonalAgent.captureLiveSnapshot")
        }
    }

    private func formatMemoryContext(_ ranked: some Sequence<RankedMemory>) -> String {
        ranked.map { item in
            let m = item.memory
            let snippet = String(m.content.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            [\(m.id.uuidString)] \(m.sourceTitle ?? m.title)
            Summary: \(m.summary)
            Content excerpt: \(snippet)
            App: \(m.sourceApplication)
            Observed: \(m.lastObservedAt.formatted())
            """
        }.joined(separator: "\n\n")
    }

    private func formatWebContext(_ results: [WebSearchResult]) -> String {
        results.prefix(6).map { "[web] \($0.title)\nURL: \($0.url)\nSnippet: \($0.snippet)" }.joined(separator: "\n\n")
    }

    private func parseStructuredResponse(
        prompt: String,
        system: String,
        memories: [Memory],
        webResults: [WebSearchResult],
        route: AnswerRoute
    ) async throws -> AssistantResponse {
        let content = try await chatCompletion(prompt: prompt, system: system)
        if let data = extractJSON(from: content),
           let payload = try? JSONDecoder().decode(QwenResponsePayload.self, from: data) {
            let used = memories.filter { mem in payload.usedMemoryIDs.contains(mem.id.uuidString) }
            let memorySources = used.map {
                ResponseSource(
                    title: $0.sourceTitle ?? $0.title,
                    url: $0.sourceURL,
                    observedAt: $0.lastObservedAt,
                    applicationName: $0.sourceApplication
                )
            }
            let filtered = CitationBuilder.filterSources(
                answer: payload.answer,
                memorySources: memorySources,
                webSources: webResults
            )
            return AssistantResponse(
                answer: AnswerSanitizer.sanitize(payload.answer),
                sources: filtered.sources,
                webSources: filtered.webSources,
                usedMemoryIDs: used.map(\.id),
                confidence: payload.confidence,
                ambiguityNotice: payload.ambiguityNotice,
                usedWebSearch: !filtered.webSources.isEmpty,
                route: route
            )
        }

        let answer = try await chatCompletion(prompt: prompt + "\n\nReply with plain text only.", system: system)
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(answer),
            sources: [],
            webSources: [],
            usedMemoryIDs: [],
            confidence: 0.7,
            ambiguityNotice: nil,
            usedWebSearch: false,
            route: route
        )
    }

    func chatCompletion(prompt: String, system: String) async throws -> String {
        try await chatCompletionFast(prompt: prompt, system: system, maxTokens: 1200, history: [])
    }

    func chatCompletionFast(
        prompt: String,
        system: String,
        maxTokens: Int = 400,
        history: [ConversationTurn] = []
    ) async throws -> String {
        let config = QwenConfiguration.current
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            throw QwenError.missingAPIKey
        }
        guard let url = URL(string: config.baseURL + "/chat/completions") else {
            throw QwenError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = [["role": "system", "content": system]]
        for turn in history.suffix(12) {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": config.textModel,
            "messages": messages,
            "temperature": 0.15,
            "max_tokens": maxTokens,
            "enable_thinking": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QwenError.requestFailed(String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        let decoded = try JSONDecoder().decode(QwenChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return Data(text[start...end].utf8)
    }
}

protocol QwenService {
    func extractMemories(from observation: ProcessedObservation) async throws -> [MemoryCandidate]
    func interpretQuery(_ query: String, currentDate: Date, timezone: TimeZone) async throws -> SearchIntent
    func generateEmbedding(for text: String) async throws -> [Float]
    func rerank(query: String, memories: [Memory]) async throws -> [RankedMemory]
    func generateResponse(query: String, memories: [Memory]) async throws -> AssistantResponse
}

private struct QwenChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

private struct QwenMemoryExtractionPayload: Decodable {
    struct ExtractedEntity: Decodable {
        let name: String
        let type: String
        let context: String?
    }

    let summary: String
    let topics: [String]
    let keywords: [String]
    let entities: [ExtractedEntity]?
    let importance: Double
    let memoryType: String

    enum CodingKeys: String, CodingKey {
        case summary, topics, keywords, entities, importance
        case memoryType = "memory_type"
    }
}

private struct QwenResponsePayload: Decodable {
    let answer: String
    let usedMemoryIDs: [String]
    let confidence: Double
    let ambiguityNotice: String?

    enum CodingKeys: String, CodingKey {
        case answer
        case usedMemoryIDs = "used_memory_ids"
        case confidence
        case ambiguityNotice = "ambiguity_notice"
    }
}

enum QwenError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Qwen API key is not configured."
        case .invalidURL: return "Invalid Qwen base URL."
        case .requestFailed(let msg): return msg
        }
    }
}
