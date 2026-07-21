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
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
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

struct OpenAIConfiguration {
    var apiKey: String?
    var baseURL: String
    var reasoningModel: String
    var utilityModel: String
    var memoryEnrichmentCooldownSeconds: TimeInterval

    var responsesURL: URL? {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: root + "/responses")
    }

    static var current: OpenAIConfiguration {
        EnvLoader.loadIfNeeded()
        let keychain = KeychainService()
        let cooldown = Double(EnvLoader.value(for: "OPENAI_MEMORY_ENRICHMENT_COOLDOWN_SECONDS") ?? "") ?? 300
        return OpenAIConfiguration(
            apiKey: keychain.read(key: "OPENAI_API_KEY") ?? EnvLoader.value(for: "OPENAI_API_KEY"),
            baseURL: EnvLoader.value(for: "OPENAI_BASE_URL") ?? "https://api.openai.com/v1",
            reasoningModel: EnvLoader.value(for: "OPENAI_REASONING_MODEL") ?? "gpt-5.6-sol",
            utilityModel: EnvLoader.value(for: "OPENAI_UTILITY_MODEL") ?? "gpt-5.6-luna",
            memoryEnrichmentCooldownSeconds: max(30, cooldown)
        )
    }
}

enum OpenAIReasoningEffort: String {
    case none
    case low
    case medium
    case high
}

enum OpenAITextVerbosity: String {
    case low
    case medium
    case high
}

struct OpenAIResponseResult: Equatable {
    let text: String
    let webResults: [WebSearchResult]
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
}

enum OpenAIResponseParser {
    static func parse(data: Data) throws -> OpenAIResponseResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.invalidResponse
        }

        var textParts: [String] = []
        var webResults: [WebSearchResult] = []
        var refusal: String?

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            textParts.append(outputText)
        }

        for item in json["output"] as? [[String: Any]] ?? [] {
            if item["type"] as? String == "message" {
                for content in item["content"] as? [[String: Any]] ?? [] {
                    switch content["type"] as? String {
                    case "output_text":
                        if let text = content["text"] as? String, !text.isEmpty, !textParts.contains(text) {
                            textParts.append(text)
                        }
                        appendCitations(from: content["annotations"], into: &webResults)
                    case "refusal":
                        refusal = content["refusal"] as? String
                    default:
                        break
                    }
                }
            }

            if item["type"] as? String == "web_search_call",
               let action = item["action"] as? [String: Any] {
                appendSources(from: action["sources"], into: &webResults)
            }
        }

        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let refusal, !refusal.isEmpty {
            throw OpenAIError.requestFailed(refusal)
        }
        guard !text.isEmpty else { throw OpenAIError.emptyResponse }

        let usage = json["usage"] as? [String: Any]
        return OpenAIResponseResult(
            text: text,
            webResults: deduplicate(webResults),
            model: json["model"] as? String,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0
        )
    }

    private static func appendCitations(from value: Any?, into results: inout [WebSearchResult]) {
        for annotation in value as? [[String: Any]] ?? [] {
            guard annotation["type"] as? String == "url_citation",
                  let url = annotation["url"] as? String,
                  !url.isEmpty else { continue }
            let title = (annotation["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(string: url)?.host
                ?? url
            results.append(WebSearchResult(title: title, url: url, snippet: ""))
        }
    }

    private static func appendSources(from value: Any?, into results: inout [WebSearchResult]) {
        for source in value as? [[String: Any]] ?? [] {
            guard let url = source["url"] as? String, !url.isEmpty else { continue }
            let title = (source["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(string: url)?.host
                ?? url
            results.append(WebSearchResult(title: title, url: url, snippet: ""))
        }
    }

    private static func deduplicate(_ results: [WebSearchResult]) -> [WebSearchResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.url).inserted }
    }
}

final class OpenAIClient {
    private let keychainService: KeychainService
    private let session: URLSession
    private let configuration: () -> OpenAIConfiguration

    init(
        keychainService: KeychainService,
        session: URLSession = .shared,
        configuration: @escaping () -> OpenAIConfiguration = { .current }
    ) {
        self.keychainService = keychainService
        self.session = session
        self.configuration = configuration
    }

    var isConfigured: Bool {
        configuration().apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func saveAPIKey(_ key: String) throws {
        try keychainService.save(key: "OPENAI_API_KEY", value: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func extractMemories(from observation: ProcessedObservation) async throws -> [MemoryCandidate] {
        guard isConfigured else { return [] }
        let textSample = String(observation.redactedText.prefix(4_000))
        guard textSample.count >= 40 else { return [] }

        let prompt = """
        Application: \(observation.applicationName)
        Window/page title: \(observation.title ?? "Unknown")
        URL: \(observation.url ?? "none")

        Visible text:
        \(textSample)
        """
        let result = try await createResponse(
            model: configuration().utilityModel,
            instructions: """
            Summarize what a Mac user is viewing so a private memory agent can recall it later.
            Keep useful facts and intent; ignore navigation chrome, cookie banners, secrets, and boilerplate.
            """,
            prompt: prompt,
            maxOutputTokens: 700,
            effort: .none,
            verbosity: .low,
            jsonSchema: Self.memoryExtractionSchema
        )

        guard let payload = try? JSONDecoder().decode(OpenAIMemoryExtractionPayload.self, from: Data(result.text.utf8)),
              !payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let type = MemoryType(rawValue: payload.memoryType) ?? (observation.url == nil ? .document : .research)
        let utility = min(1, max(0.3, payload.importance))
        let entities = payload.entities.map { MemoryEntity(type: $0.type, name: $0.name, context: $0.context) }

        return [MemoryCandidate(
            id: UUID(),
            type: entities.contains(where: { $0.type == "person" }) ? .person : type,
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

    func classifyRoute(query: String, webSearchEnabled: Bool) async throws -> RouteDecision? {
        let prompt = """
        Classify this user message for a personal AI assistant with these routes:
        - direct: general knowledge, math, definitions, coding concepts, creative work
        - memory: the user's private past screen history or personal situation
        - web: current internet information
        - memory_and_web: connects past activity with current internet information
        - live_screen: the current visible window, page, email, or code

        Web search enabled: \(webSearchEnabled)
        User message: \(query)

        Prefer live_screen when the user refers to what is visible now. Greetings are direct. Historical facts do not need web.
        If web search is disabled, do not choose web or memory_and_web.
        """
        let result = try await createResponse(
            model: configuration().utilityModel,
            instructions: "Classify conservatively. Use the model only for ambiguous cases left by local routing.",
            prompt: prompt,
            maxOutputTokens: 250,
            effort: .none,
            verbosity: .low,
            jsonSchema: Self.routeSchema
        )
        guard let payload = try? JSONDecoder().decode(OpenAIRoutePayload.self, from: Data(result.text.utf8)) else {
            return nil
        }
        var route = payload.route
        if !webSearchEnabled && (route == .web || route == .memoryAndWeb) {
            route = route == .memoryAndWeb ? .memory : .direct
        }
        return RouteDecision(route: route, searchQuery: payload.searchQuery, confidence: payload.confidence, reason: payload.reason)
    }

    func generateDirectResponse(
        query: String,
        personality: String = "",
        history: [ConversationTurn] = []
    ) async throws -> AssistantResponse {
        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            You are iAletheia, a warm, capable personal AI assistant. Answer directly, accurately, and concisely.
            Use conversation history for references to earlier messages. Never invent screen or memory context.
            \(AnswerSanitizer.plainTextStyle)
            \(personality)
            """,
            prompt: query,
            history: history,
            maxOutputTokens: 900,
            effort: .low,
            verbosity: .low
        )
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(result.text),
            sources: [],
            usedMemoryIDs: [],
            confidence: 0.88,
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
        let prompt = """
        User question: \(query)

        LIVE SCREEN SNAPSHOT:
        \(snapshot.contextBlock())
        """
        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            You are iAletheia with access to the user's Mac screen snapshot. Use only that snapshot and relevant chat history.
            Identify the active app and window, then answer with concrete visible details. Treat OCR fragments cautiously.
            For code review, focus on real logic, API, type, and compile issues. For an email/message reply, write a polished copy-ready draft.
            Never ask for content already present in the snapshot and never invent unrelated apps or screen details.
            \(AnswerSanitizer.plainTextStyle)
            \(personality)
            """,
            prompt: prompt,
            history: history,
            maxOutputTokens: 1_200,
            effort: .low,
            verbosity: .medium
        )
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(result.text),
            sources: [ResponseSource(
                title: snapshot.windowTitle ?? snapshot.applicationName,
                url: snapshot.url,
                observedAt: snapshot.capturedAt,
                applicationName: snapshot.applicationName
            )],
            usedMemoryIDs: [],
            confidence: 0.92,
            ambiguityNotice: nil,
            route: .liveScreen
        )
    }

    func generateSessionAwareResponse(
        query: String,
        history: [ConversationTurn],
        screenContext: String?,
        personality: String = ""
    ) async throws -> AssistantResponse {
        var prompt = "User question: \(query)"
        if let screenContext, !screenContext.isEmpty {
            prompt += "\n\nCURRENT/RECENT SCREEN CONTEXT:\n\(String(screenContext.prefix(12_000)))"
        }
        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            Continue the ongoing iAletheia chat. Resolve this/that/it using the conversation and screen context.
            Never invent missing screen details or ask for context that is already supplied.
            \(AnswerSanitizer.plainTextStyle)
            \(personality)
            """,
            prompt: prompt,
            history: history,
            maxOutputTokens: 1_200,
            effort: .medium,
            verbosity: .medium
        )
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(result.text),
            sources: [],
            usedMemoryIDs: [],
            confidence: 0.9,
            ambiguityNotice: nil,
            route: .direct
        )
    }

    static func localLiveScreenAnswer(query: String, snapshot: LiveScreenSnapshot) -> AssistantResponse {
        var parts = ["Right now you're in \(snapshot.applicationName)"]
        if let title = snapshot.windowTitle, !title.isEmpty { parts.append("viewing \"\(title)\"") }
        if let url = snapshot.url, !url.isEmpty { parts.append("(\(url))") }
        let excerpt = snapshot.visibleText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 20 }
            .prefix(3)
            .joined(separator: " ")
        if !excerpt.isEmpty { parts.append("Visible content includes: \(String(excerpt.prefix(320)))") }
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(parts.joined(separator: ". ") + "."),
            sources: [ResponseSource(
                title: snapshot.windowTitle ?? snapshot.applicationName,
                url: snapshot.url,
                observedAt: snapshot.capturedAt,
                applicationName: snapshot.applicationName
            )],
            usedMemoryIDs: [],
            confidence: 0.75,
            ambiguityNotice: nil,
            route: .liveScreen
        )
    }

    func generateMemoryResponse(
        query: String,
        rankedMemories: [RankedMemory],
        personality: String = ""
    ) async throws -> AssistantResponse {
        let memories = rankedMemories.map(\.memory)
        guard !memories.isEmpty else {
            return AssistantResponse(
                answer: "I don't have a personal memory about that yet. Keep working and browsing -- I'll quietly learn from your screen.",
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.3,
                ambiguityNotice: "No relevant personal memories found.",
                route: .memory
            )
        }

        let memorySlice = Array(rankedMemories.prefix(8))
        let memorySources = memorySlice.map { item in
            ResponseSource(
                title: item.memory.sourceTitle ?? item.memory.title,
                url: item.memory.sourceURL,
                observedAt: item.memory.lastObservedAt,
                applicationName: item.memory.sourceApplication
            )
        }
        let prompt = """
        User query: \(query)

        Numbered sources:
        \(CitationBuilder.numberedSourceBlock(sources: memorySources, webResults: []))

        Personal memories:
        \(formatMemoryContext(memorySlice))
        """
        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            You are iAletheia with access to the user's private screen memories supplied in the prompt.
            Ground personal answers in specific supplied evidence. Never invent a URL or fact. Cite used numbered sources inline.
            \(CitationBuilder.citationInstruction)
            \(AnswerSanitizer.plainTextStyle)
            \(personality)
            """,
            prompt: prompt,
            maxOutputTokens: 1_200,
            effort: .medium,
            verbosity: .medium,
            jsonSchema: Self.answerSchema
        )
        return structuredAssistantResponse(
            result: result,
            memories: memories,
            memorySources: memorySources,
            route: .memory
        )
    }

    func generateWithOpenAIWebSearch(
        query: String,
        rankedMemories: [RankedMemory] = [],
        personality: String = ""
    ) async throws -> AssistantResponse {
        let memorySlice = Array(rankedMemories.prefix(6))
        let memories = memorySlice.map(\.memory)
        let route: AnswerRoute = memories.isEmpty ? .web : .memoryAndWeb
        let memorySources = memorySlice.map { item in
            ResponseSource(
                title: item.memory.sourceTitle ?? item.memory.title,
                url: item.memory.sourceURL,
                observedAt: item.memory.lastObservedAt,
                applicationName: item.memory.sourceApplication
            )
        }
        var prompt = "User query: \(query)"
        if !memorySlice.isEmpty {
            prompt += """


            Numbered private memory sources:
            \(CitationBuilder.numberedSourceBlock(sources: memorySources, webResults: []))

            Private screen memories:
            \(formatMemoryContext(memorySlice))
            """
        }

        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            You are iAletheia with native live web search. Search when needed and answer with current, accurate information.
            Cite web claims using the citations produced by the web tool. If private memories are supplied, cite them as [1], [2], and clearly separate them from current web findings.
            Never invent sources, titles, URLs, or personal facts.
            \(AnswerSanitizer.plainTextStyle)
            \(personality)
            """,
            prompt: prompt,
            maxOutputTokens: 1_600,
            effort: .medium,
            verbosity: .medium,
            useWebSearch: true
        )

        let referenced = CitationBuilder.referencedCitationIDs(in: result.text)
        let usedMemories = memorySlice.enumerated().compactMap { index, item in
            referenced.contains(index + 1) ? item.memory : nil
        }
        let usedIDs = Set(usedMemories.map(\.id))
        let usedSources = memorySlice.compactMap { item -> ResponseSource? in
            guard usedIDs.contains(item.memory.id) else { return nil }
            return ResponseSource(
                title: item.memory.sourceTitle ?? item.memory.title,
                url: item.memory.sourceURL,
                observedAt: item.memory.lastObservedAt,
                applicationName: item.memory.sourceApplication
            )
        }
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(result.text),
            sources: usedSources,
            webSources: result.webResults,
            usedMemoryIDs: usedMemories.map(\.id),
            confidence: result.webResults.isEmpty ? 0.62 : 0.9,
            ambiguityNotice: result.webResults.isEmpty ? "The web tool returned no citeable sources." : nil,
            usedWebSearch: true,
            route: route
        )
    }

    func generateShowMePlan(
        query: String,
        snapshot: LiveScreenSnapshot?,
        appName: String?,
        windowTitle: String?
    ) async throws -> ShowMePlan {
        var prompt = """
        User request: \(query)
        Active app: \(appName ?? "unknown")
        Window title: \(windowTitle ?? "unknown")
        """
        if let snapshot { prompt += "\n\nLIVE SCREEN SNAPSHOT:\n\(snapshot.contextBlock())" }

        let result = try await createResponse(
            model: configuration().reasoningModel,
            instructions: """
            Create a 3-to-6-step Show Me walkthrough for the current app. The user performs every click.
            Use exact visible labels where possible. Valid region hints: menubar, ribbon, toolbar, toolbar_left, top, top_left, bottom, left, right, center, compose_top.
            Never invent unrelated apps or claim you will click for the user.
            """,
            prompt: prompt,
            maxOutputTokens: 1_000,
            effort: .low,
            verbosity: .low,
            jsonSchema: Self.showMeSchema
        )
        guard let plan = try? JSONDecoder().decode(ShowMePlan.self, from: Data(result.text.utf8)), !plan.steps.isEmpty else {
            throw OpenAIError.requestFailed("Could not parse the Show Me plan.")
        }
        return plan
    }

    private func structuredAssistantResponse(
        result: OpenAIResponseResult,
        memories: [Memory],
        memorySources: [ResponseSource],
        route: AnswerRoute
    ) -> AssistantResponse {
        guard let payload = try? JSONDecoder().decode(OpenAIAnswerPayload.self, from: Data(result.text.utf8)) else {
            return AssistantResponse(
                answer: AnswerSanitizer.sanitize(result.text),
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.65,
                ambiguityNotice: "The model returned an unexpected structured response.",
                route: route
            )
        }
        let wanted = Set(payload.usedMemoryIDs)
        let used = memories.filter { wanted.contains($0.id.uuidString) }
        let usedIDs = Set(used.map(\.id))
        let sources = zip(memories, memorySources).compactMap { memory, source in
            usedIDs.contains(memory.id) ? source : nil
        }
        return AssistantResponse(
            answer: AnswerSanitizer.sanitize(payload.answer),
            sources: sources,
            usedMemoryIDs: used.map(\.id),
            confidence: min(1, max(0, payload.confidence)),
            ambiguityNotice: payload.ambiguityNotice,
            route: route
        )
    }

    private func formatMemoryContext(_ ranked: [RankedMemory]) -> String {
        ranked.enumerated().map { index, item in
            let memory = item.memory
            return """
            [\(index + 1)] id=\(memory.id.uuidString) title=\(memory.sourceTitle ?? memory.title)
            Summary: \(memory.summary)
            Content excerpt: \(String(memory.content.prefix(500)))
            App: \(memory.sourceApplication)
            Observed: \(memory.lastObservedAt.formatted())
            """
        }.joined(separator: "\n\n")
    }

    private func createResponse(
        model: String,
        instructions: String,
        prompt: String,
        history: [ConversationTurn] = [],
        maxOutputTokens: Int,
        effort: OpenAIReasoningEffort,
        verbosity: OpenAITextVerbosity,
        jsonSchema: [String: Any]? = nil,
        useWebSearch: Bool = false
    ) async throws -> OpenAIResponseResult {
        let config = configuration()
        guard let apiKey = config.apiKey, !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        guard let url = config.responsesURL else { throw OpenAIError.invalidURL }

        var input = history.suffix(12).map { ["role": $0.role, "content": $0.content] }
        input.append(["role": "user", "content": prompt])

        var textConfiguration: [String: Any] = ["verbosity": verbosity.rawValue]
        if let jsonSchema { textConfiguration["format"] = jsonSchema }

        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "reasoning": ["effort": effort.rawValue],
            "text": textConfiguration,
            "max_output_tokens": maxOutputTokens,
            "store": false,
            "safety_identifier": OpenAISafetyIdentifier.current()
        ]
        if useWebSearch {
            body["tools"] = [["type": "web_search", "search_context_size": "low"]]
            body["tool_choice"] = "auto"
            body["include"] = ["web_search_call.action.sources"]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = useWebSearch ? 120 : 90
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIError.requestFailed(Self.errorMessage(from: data, statusCode: http.statusCode))
        }
        return try OpenAIResponseParser.parse(data: data)
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "OpenAI request failed (\(statusCode)): \(message)"
        }
        return "OpenAI request failed with HTTP \(statusCode)."
    }

    private static let answerSchema: [String: Any] = [
        "type": "json_schema",
        "name": "memory_answer",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "answer": ["type": "string"],
                "used_memory_ids": ["type": "array", "items": ["type": "string"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "ambiguity_notice": ["type": ["string", "null"]]
            ],
            "required": ["answer", "used_memory_ids", "confidence", "ambiguity_notice"],
            "additionalProperties": false
        ]
    ]

    private static let memoryExtractionSchema: [String: Any] = [
        "type": "json_schema",
        "name": "memory_extraction",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "topics": ["type": "array", "items": ["type": "string"]],
                "keywords": ["type": "array", "items": ["type": "string"]],
                "entities": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "type": ["type": "string"],
                            "context": ["type": ["string", "null"]]
                        ],
                        "required": ["name", "type", "context"],
                        "additionalProperties": false
                    ]
                ],
                "memory_type": ["type": "string"],
                "importance": ["type": "number", "minimum": 0, "maximum": 1]
            ],
            "required": ["summary", "topics", "keywords", "entities", "memory_type", "importance"],
            "additionalProperties": false
        ]
    ]

    private static let routeSchema: [String: Any] = [
        "type": "json_schema",
        "name": "query_route",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "route": ["type": "string", "enum": ["direct", "memory", "web", "memory_and_web", "live_screen"]],
                "search_query": ["type": ["string", "null"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "reason": ["type": "string"]
            ],
            "required": ["route", "search_query", "confidence", "reason"],
            "additionalProperties": false
        ]
    ]

    private static let showMeSchema: [String: Any] = [
        "type": "json_schema",
        "name": "show_me_plan",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "intro": ["type": "string"],
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "instruction": ["type": "string"],
                            "target_hints": ["type": "array", "items": ["type": "string"]],
                            "region_hint": ["type": ["string", "null"]],
                            "done_hint": ["type": ["string", "null"]]
                        ],
                        "required": ["title", "instruction", "target_hints", "region_hint", "done_hint"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["intro", "steps"],
            "additionalProperties": false
        ]
    ]
}

private enum OpenAISafetyIdentifier {
    private static let defaultsKey = "ialetheia.openaiSafetyIdentifier"

    static func current() -> String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let value = "ialetheia_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(value, forKey: defaultsKey)
        return value
    }
}

private struct OpenAIMemoryExtractionPayload: Decodable {
    struct ExtractedEntity: Decodable {
        let name: String
        let type: String
        let context: String?
    }

    let summary: String
    let topics: [String]
    let keywords: [String]
    let entities: [ExtractedEntity]
    let importance: Double
    let memoryType: String

    enum CodingKeys: String, CodingKey {
        case summary, topics, keywords, entities, importance
        case memoryType = "memory_type"
    }
}

private struct OpenAIAnswerPayload: Decodable {
    let answer: String
    let usedMemoryIDs: [String]
    let confidence: Double
    let ambiguityNotice: String?

    enum CodingKeys: String, CodingKey {
        case answer, confidence
        case usedMemoryIDs = "used_memory_ids"
        case ambiguityNotice = "ambiguity_notice"
    }
}

private struct OpenAIRoutePayload: Decodable {
    let route: AnswerRoute
    let searchQuery: String?
    let confidence: Double
    let reason: String

    enum CodingKeys: String, CodingKey {
        case route, confidence, reason
        case searchQuery = "search_query"
    }
}

enum OpenAIError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case emptyResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenAI API key is not configured."
        case .invalidURL: return "The OpenAI base URL is invalid."
        case .invalidResponse: return "OpenAI returned an invalid response."
        case .emptyResponse: return "OpenAI returned an empty response."
        case .requestFailed(let message): return message
        }
    }
}
