import Foundation
import ApplicationServices
import CoreGraphics

/// Orchestrates smart routing: direct answer, personal memory, web search, or hybrid.
final class PersonalAgent {
    private let qwenClient: QwenClient
    private let webSearchService: WebSearchService
    private let queryRouter: QueryRouter
    private let hybridRetriever: HybridRetriever
    private let chatLearningService: ChatLearningService
    private let observationPipeline: ObservationPipeline

    private let memoryRelevanceThreshold = 0.12
    private let strongMemoryThreshold = 0.22

    init(
        qwenClient: QwenClient,
        webSearchService: WebSearchService,
        hybridRetriever: HybridRetriever,
        chatLearningService: ChatLearningService,
        observationPipeline: ObservationPipeline
    ) {
        self.qwenClient = qwenClient
        self.webSearchService = webSearchService
        self.queryRouter = QueryRouter(qwenClient: qwenClient)
        self.hybridRetriever = hybridRetriever
        self.chatLearningService = chatLearningService
        self.observationPipeline = observationPipeline
    }

    func answer(
        query: String,
        webSearchEnabled: Bool,
        profile: UserProfile,
        agentPreferences: AgentPreferences,
        conversationHistory: [ConversationTurn] = [],
        lastScreenContext: String? = nil,
        onStatus: AgentStatusHandler? = nil
    ) async throws -> AgentAnswer {
        let personality = agentPreferences.personalityPrompt(profile: profile)
            + "\n"
            + chatLearningService.learnedPersonalityAddendum()
        let report = onStatus ?? { _ in }
        let history = Array(conversationHistory.suffix(12))

        report(.thinking)

        // Fast path: live screen — skip memory retrieval and LLM routing entirely.
        if QueryRouter.isLiveScreenQuery(query) {
            return try await answerLiveScreen(
                query: query,
                personality: personality,
                history: history,
                report: report
            )
        }

        // Session follow-ups ("is there any error in this?") use chat + screen context.
        if !history.isEmpty, SessionFollowUp.isFollowUp(query) {
            return try await answerSessionFollowUp(
                query: query,
                personality: personality,
                history: history,
                lastScreenContext: lastScreenContext,
                report: report
            )
        }

        guard qwenClient.isConfigured else {
            report(.retrieving)
            let ranked = try await hybridRetriever.retrieve(query: query)
            let relevant = ranked.filter { $0.score >= memoryRelevanceThreshold }
            return AgentAnswer(
                response: AssistantResponse.localFallback(query: query, memories: relevant.map(\.memory)),
                route: .memory,
                statusText: AgentActivityPhase.retrieving.displayText
            )
        }

        let localDecision = queryRouter.classifyLocally(query: query, webSearchEnabled: webSearchEnabled)
        let decision: RouteDecision
        var ranked: [RankedMemory]

        if let localDecision {
            decision = localDecision
            if localDecision.route == .liveScreen {
                return try await answerLiveScreen(
                    query: query,
                    personality: personality,
                    history: history,
                    report: report
                )
            }
            if needsMemoryRetrieval(for: localDecision) {
                report(.retrieving)
                ranked = try await hybridRetriever.retrieve(query: query)
            } else {
                ranked = []
            }
        } else {
            report(.retrieving)
            async let retrieveTask = hybridRetriever.retrieve(query: query)
            async let classifyTask = queryRouter.classify(query: query, webSearchEnabled: webSearchEnabled)
            ranked = try await retrieveTask
            report(.thinking)
            decision = try await classifyTask
        }

        let relevant = ranked.filter { $0.score >= memoryRelevanceThreshold }
        let resolved = resolveRoute(
            decision: decision,
            query: query,
            relevantMemories: relevant,
            webSearchEnabled: webSearchEnabled
        )

        switch resolved.route {
        case .liveScreen:
            return try await answerLiveScreen(
                query: query,
                personality: personality,
                history: history,
                report: report
            )

        case .direct:
            report(.drafting)
            let response = try await qwenClient.generateDirectResponse(
                query: query, personality: personality, history: history
            )
            return AgentAnswer(response: response, route: .direct, statusText: AgentActivityPhase.drafting.displayText)

        case .memory:
            if relevant.isEmpty {
                report(.retrieving)
                ranked = try await hybridRetriever.retrieve(query: query)
            }
            let memories = ranked.filter { $0.score >= memoryRelevanceThreshold }
            report(.drafting)
            let response = try await qwenClient.generateMemoryResponse(
                query: query, rankedMemories: memories, personality: personality
            )
            return AgentAnswer(response: response, route: .memory, statusText: AgentActivityPhase.drafting.displayText)

        case .web:
            report(.searching)
            let webQuery = enrichWebQuery(query, profile: profile)
            let response = try await qwenClient.generateWithQwenWebSearch(
                query: webQuery,
                rankedMemories: [],
                personality: personality
            )
            return AgentAnswer(response: response, route: .web, statusText: AgentActivityPhase.searching.displayText)

        case .memoryAndWeb:
            if relevant.isEmpty {
                report(.retrieving)
                ranked = try await hybridRetriever.retrieve(query: query)
            }
            let memories = ranked.filter { $0.score >= memoryRelevanceThreshold }
            report(.searching)
            let webQuery = enrichWebQuery(query, profile: profile)
            let response = try await qwenClient.generateWithQwenWebSearch(
                query: webQuery,
                rankedMemories: memories,
                personality: personality
            )
            return AgentAnswer(response: response, route: .memoryAndWeb, statusText: AgentActivityPhase.searching.displayText)
        }
    }

    private func answerSessionFollowUp(
        query: String,
        personality: String,
        history: [ConversationTurn],
        lastScreenContext: String?,
        report: @escaping AgentStatusHandler
    ) async throws -> AgentAnswer {
        report(.readingScreen)
        var screenContext = lastScreenContext
        // Refresh live screen for follow-ups about code/errors when possible.
        if let snapshot = await observationPipeline.captureLiveSnapshot() {
            screenContext = snapshot.contextBlock()
        }

        report(.drafting)
        if qwenClient.isConfigured {
            let response = try await qwenClient.generateSessionAwareResponse(
                query: query,
                history: history,
                screenContext: screenContext,
                personality: personality
            )
            return AgentAnswer(
                response: response,
                route: .direct,
                statusText: AgentActivityPhase.drafting.displayText,
                screenContext: screenContext
            )
        }

        let fallback = screenContext.map {
            "Based on the current screen:\n\(String($0.prefix(1200)))"
        } ?? "I need a bit more context — open the file and ask again, or paste the snippet."
        return AgentAnswer(
            response: AssistantResponse(
                answer: AnswerSanitizer.sanitize(fallback),
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.4,
                ambiguityNotice: nil,
                route: .direct
            ),
            route: .direct,
            statusText: AgentActivityPhase.drafting.displayText,
            screenContext: screenContext
        )
    }

    private func answerLiveScreen(
        query: String,
        personality: String,
        history: [ConversationTurn] = [],
        report: @escaping AgentStatusHandler
    ) async throws -> AgentAnswer {
        report(.readingScreen)
        guard let snapshot = await observationPipeline.captureLiveSnapshot() else {
            let screenOK = CGPreflightScreenCaptureAccess()
            let axOK = AXIsProcessTrusted()
            let detail: String
            if !screenOK || !axOK {
                detail = "Permissions check: Screen Recording \(screenOK ? "OK" : "missing"), Accessibility \(axOK ? "OK" : "missing")."
            } else {
                detail = "Permissions look fine, but no other app window was detected behind this chat. Click once on the browser or app you want me to see, then ask again."
            }
            return AgentAnswer(
                response: AssistantResponse(
                    answer: "I couldn't identify an active window to read. \(detail)",
                    sources: [],
                    usedMemoryIDs: [],
                    confidence: 0.2,
                    ambiguityNotice: detail,
                    route: .liveScreen
                ),
                route: .liveScreen,
                statusText: AgentActivityPhase.readingScreen.displayText
            )
        }

        report(.drafting)
        let response: AssistantResponse
        if qwenClient.isConfigured {
            do {
                response = try await qwenClient.generateLiveScreenResponse(
                    query: query,
                    snapshot: snapshot,
                    personality: personality,
                    history: history
                )
            } catch {
                response = QwenClient.localLiveScreenAnswer(query: query, snapshot: snapshot)
            }
        } else {
            response = QwenClient.localLiveScreenAnswer(query: query, snapshot: snapshot)
        }

        return AgentAnswer(
            response: response,
            route: .liveScreen,
            statusText: AgentActivityPhase.drafting.displayText,
            screenContext: snapshot.contextBlock()
        )
    }

    private func needsMemoryRetrieval(for decision: RouteDecision) -> Bool {
        switch decision.route {
        case .memory, .memoryAndWeb:
            return true
        case .web, .direct, .liveScreen:
            return false
        }
    }

    private func enrichWebQuery(_ query: String, profile: UserProfile) -> String {
        let lower = query.lowercased()
        let nameHints = ["my name", "search me", "searching my name", "search for me"]
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, nameHints.contains(where: { lower.contains($0) }) else {
            return query
        }
        return """
        \(query)

        The user's name is: \(name)
        Search the web for this person and list the top results with titles and URLs.
        """
    }

    private func resolveRoute(
        decision: RouteDecision,
        query: String,
        relevantMemories: [RankedMemory],
        webSearchEnabled: Bool
    ) -> (route: AnswerRoute, searchQuery: String?) {
        if decision.reason == "live_screen" || decision.route == .liveScreen {
            return (.liveScreen, nil)
        }

        if decision.reason == "greeting" {
            return (.direct, nil)
        }

        if webSearchEnabled && (decision.reason == "explicit_web_search" || QueryRouter.isExplicitWebSearch(query)) {
            return (.web, decision.searchQuery ?? QueryRouter.optimizedWebQuery(from: query))
        }

        if webSearchEnabled && decision.route == .web {
            return (decision.route, decision.searchQuery)
        }

        if decision.route == .direct || decision.reason == "model_knowledge" {
            return (.direct, nil)
        }

        guard !relevantMemories.isEmpty else {
            return (decision.route, decision.searchQuery)
        }

        let topScore = relevantMemories.first?.score ?? 0
        let isPersonal = QueryRouter.isPersonalLifeQuestion(query)
        let hasStrongMemory = topScore >= strongMemoryThreshold
        let hasPersonalMemory = isPersonal && topScore >= memoryRelevanceThreshold

        if hasStrongMemory || hasPersonalMemory {
            switch decision.route {
            case .web:
                return webSearchEnabled ? (.memoryAndWeb, decision.searchQuery) : (.memory, nil)
            case .memoryAndWeb:
                return (.memoryAndWeb, decision.searchQuery)
            case .direct, .memory, .liveScreen:
                if webSearchEnabled && shouldBlendWeb(query: query, decision: decision) {
                    return (.memoryAndWeb, decision.searchQuery ?? QueryRouter.optimizedWebQuery(from: query))
                }
                return (.memory, nil)
            }
        }

        if isPersonal && !relevantMemories.isEmpty {
            return (.memory, nil)
        }

        return (decision.route, decision.searchQuery)
    }

    private func shouldBlendWeb(query: String, decision: RouteDecision) -> Bool {
        let lower = query.lowercased()
        let blendSignals = [
            "compare", "versus", "vs ", "latest", "current rate", "market", "benchmark",
            "industry average", "typical salary", "right now"
        ]
        return blendSignals.contains(where: { lower.contains($0) }) || decision.route == .memoryAndWeb
    }
}

struct AgentAnswer: Equatable {
    let response: AssistantResponse
    let route: AnswerRoute
    let statusText: String
    /// Live screen block from this turn — kept for follow-ups in the same session.
    var screenContext: String? = nil
}

struct AgentPlan: Equatable {
    let route: AnswerRoute
    let searchQuery: String?
    let strategy: String

    var useWebSearch: Bool { route == .web || route == .memoryAndWeb }
}
