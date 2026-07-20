import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isObserving = false
    @Published var isPrivateMode = false
    @Published var cloudProcessingEnabled = true {
        didSet { AppConfiguration.cloudProcessingEnabled = cloudProcessingEnabled }
    }
    @Published var webSearchEnabled = true
    @Published var showMeEnabled = false
    @Published var activeShowMeGuide: ShowMeGuideSession?
    @Published var showMeStatusText: String?
    @Published var isSearchingWeb = false
    @Published var queryStatusText = AgentActivityPhase.thinking.displayText
    @Published var agentActivityPhase: AgentActivityPhase = .thinking
    @Published var lastObservationSummary: String?
    @Published var lastError: String?
    @Published var memories: [Memory] = []
    @Published var recentObservations: [ProcessedObservationRecord] = []
    @Published var episodes: [Episode] = []
    @Published var assistantResponse: AssistantResponse?
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatSessions: [ChatSession] = []
    @Published var activeChatSessionID: UUID?
    @Published var isQuerying = false
    @Published var permissionsGranted = PermissionStatus()
    @Published var showOwlWidget = true
    @Published var requestedSection: AppSection?

    let preferencesStore = UserPreferencesStore()

    var safeObservationSummary: String? {
        DisplaySanitizer.safeSummary(lastObservationSummary)
    }

    var safeErrorMessage: String? {
        DisplaySanitizer.safeError(lastError)
    }

    var qwenConfigured: Bool {
        (try? dependencies.qwenClient.isConfigured) ?? false
    }

    var activeChatSessionTitle: String {
        guard let id = activeChatSessionID,
              let session = chatSessions.first(where: { $0.id == id }) else {
            return "New chat"
        }
        return session.title
    }

    private var container: DependencyContainer?
    private var observationTask: Task<Void, Never>?
    private var decayTask: Task<Void, Never>?
    private var showMeWatchTask: Task<Void, Never>?
    /// Screen context from the last live-screen / follow-up turn in this session.
    private var lastScreenContext: String?
    private var showMeBaseline: ShowMeActivitySnapshot?
    private var lastShowMeCorrectionAt: Date?

    var dependencies: DependencyContainer {
        get throws {
            if let container { return container }
            let created = try DependencyContainer()
            container = created
            return created
        }
    }

    init() {
        cloudProcessingEnabled = AppConfiguration.cloudProcessingEnabled
        NotificationCenter.default.addObserver(
            forName: .iAletheiaEnsureOwlWidget,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureOwlWidgetShown() }
        }
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            let deps = try dependencies
            ensureOwlWidgetShown()

            memories = try deps.memoryRepository.fetchAll(limit: 200)
            recentObservations = try deps.observationRepository.fetchRecent(limit: 50)
            episodes = try deps.episodeService.fetchRecent(limit: 30)
            reloadChatSessions()
            restoreOrStartChatSession()
            reloadVectorIndex(deps: deps)

            Task { @MainActor in
                do {
                    let deps = try self.dependencies
                    let merged = try deps.smartEntityMemory.consolidateExistingMemories(vectorStore: deps.vectorStore)
                    if merged > 0 {
                        self.memories = try deps.memoryRepository.fetchAll(limit: 200)
                        self.reloadVectorIndex(deps: deps)
                    }
                } catch {
                    self.lastError = error.localizedDescription
                }
            }

            permissionsGranted = await checkPermissions()
            requestPermissions()
            if !isPrivateMode {
                startObservation()
            }
        } catch {
            lastError = error.localizedDescription
            ensureOwlWidgetShown()
            seedWelcomeMessageIfNeeded()
        }
    }

    func ensureOwlWidgetShown() {
        guard showOwlWidget else { return }
        OwlWidgetController.shared.show(appState: self)
    }

    private func seedWelcomeMessageIfNeeded() {
        guard chatMessages.isEmpty else { return }
        chatMessages.append(ChatMessage(
            role: .assistant,
            text: "Hi — I'm iAletheia, your personal agent. Ask about your past work, get direct answers, or search the web when needed. Set up your profile and agent personality in the app to personalize responses.",
            timestamp: Date()
        ))
    }

    func reloadChatSessions() {
        guard let deps = try? dependencies else { return }
        chatSessions = (try? deps.chatHistoryRepository.fetchSessions()) ?? []
    }

    private func restoreOrStartChatSession() {
        if let active = chatSessions.first(where: { $0.isActive }),
           let deps = try? dependencies,
           let stored = try? deps.chatHistoryRepository.fetchMessages(sessionID: active.id),
           !stored.isEmpty {
            activeChatSessionID = active.id
            chatMessages = stored.map { $0.toChatMessage() }
            lastScreenContext = nil
            return
        }
        startNewChatSession()
    }

    /// Starts a fresh chat session. Ends the previous one if it had real messages.
    func startNewChatSession() {
        if let currentID = activeChatSessionID,
           let deps = try? dependencies {
            let hasUserMessages = chatMessages.contains { $0.role == .user }
            if hasUserMessages {
                try? deps.chatHistoryRepository.endSession(id: currentID)
            } else {
                try? deps.chatHistoryRepository.deleteSession(id: currentID)
            }
        }
        let session = ChatSession()
        activeChatSessionID = session.id
        chatMessages = []
        lastScreenContext = nil
        if let deps = try? dependencies {
            try? deps.chatHistoryRepository.createSession(session)
        }
        seedWelcomeMessageIfNeeded()
        reloadChatSessions()
    }

    func openChatSession(id: UUID) {
        guard let deps = try? dependencies else { return }
        if let currentID = activeChatSessionID, currentID != id {
            let hasUserMessages = chatMessages.contains { $0.role == .user }
            if hasUserMessages {
                try? deps.chatHistoryRepository.endSession(id: currentID)
            }
        }
        guard let messages = try? deps.chatHistoryRepository.fetchMessages(sessionID: id) else { return }
        activeChatSessionID = id
        chatMessages = messages.map { $0.toChatMessage() }
        lastScreenContext = nil
        // Re-open as active session
        if var session = chatSessions.first(where: { $0.id == id }) {
            session.endedAt = nil
            session.updatedAt = Date()
            try? deps.chatHistoryRepository.updateSession(session)
        }
        reloadChatSessions()
    }

    func deleteChatSession(id: UUID) {
        guard let deps = try? dependencies else { return }
        try? deps.chatHistoryRepository.deleteSession(id: id)
        if activeChatSessionID == id {
            activeChatSessionID = nil
            chatMessages = []
            lastScreenContext = nil
            startNewChatSession()
        } else {
            reloadChatSessions()
        }
    }

    func messagesForHistorySession(id: UUID) -> [ChatMessage] {
        guard let deps = try? dependencies,
              let stored = try? deps.chatHistoryRepository.fetchMessages(sessionID: id) else {
            return []
        }
        return stored.map { $0.toChatMessage() }
    }

    private func conversationHistoryTurns() -> [ConversationTurn] {
        chatMessages.compactMap { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Skip the seeded welcome so it doesn't dilute follow-up context.
            if message.role == .assistant,
               text.hasPrefix("Hi — I'm iAletheia"),
               !chatMessages.contains(where: { $0.role == .user }) {
                return nil
            }
            return ConversationTurn(
                role: message.role == .user ? "user" : "assistant",
                content: text
            )
        }
    }

    private func ensureActiveSession(firstUserMessage: String) throws -> UUID {
        let deps = try dependencies
        if let id = activeChatSessionID {
            return id
        }
        let session = ChatSession(title: ChatSession.title(from: firstUserMessage))
        try deps.chatHistoryRepository.createSession(session)
        activeChatSessionID = session.id
        reloadChatSessions()
        return session.id
    }

    private func persistChatTurn(sessionID: UUID, message: ChatMessage) {
        guard let deps = try? dependencies else { return }
        let role: StoredChatMessage.Role = message.role == .user ? .user : .assistant
        var citationsJSON: String?
        if !message.citations.isEmpty,
           let data = try? JSONEncoder().encode(message.citations),
           let json = String(data: data, encoding: .utf8) {
            citationsJSON = json
        }
        let stored = StoredChatMessage(
            id: message.id,
            sessionID: sessionID,
            role: role,
            text: message.text,
            citationsJSON: citationsJSON,
            timestamp: message.timestamp
        )
        try? deps.chatHistoryRepository.appendMessage(stored)

        var session = chatSessions.first(where: { $0.id == sessionID }) ?? ChatSession(id: sessionID)
        if message.role == .user, session.messageCount == 0 || session.title == "New chat" {
            session.title = ChatSession.title(from: message.text)
        }
        if message.role == .user {
            session.preview = message.text
        } else if session.preview.isEmpty {
            session.preview = message.text
        }
        session.messageCount += 1
        session.updatedAt = Date()
        session.endedAt = nil
        try? deps.chatHistoryRepository.updateSession(session)
        reloadChatSessions()
    }

    func openMainApp(section: AppSection = .home) {
        requestedSection = section
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    func openChat() {
        OwlWidgetController.shared.toggleChat(appState: self)
    }

    private func reloadVectorIndex(deps: DependencyContainer) {
        deps.vectorStore.clear()
        for memory in memories where memory.memoryState != .deleted && memory.memoryState != .expired && memory.memoryState != .superseded {
            if let embedding = memory.embedding {
                deps.vectorStore.upsert(memoryID: memory.id, embedding: embedding)
            } else {
                let embedding = deps.vectorStore.embed(text: memory.title + " " + memory.summary)
                deps.vectorStore.upsert(memoryID: memory.id, embedding: embedding)
            }
        }
    }

    func checkPermissions() async -> PermissionStatus {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        return PermissionStatus(screenRecording: screen, accessibility: accessibility)
    }

    func requestPermissions() {
        CGRequestScreenCaptureAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        Task {
            permissionsGranted = await checkPermissions()
        }
    }

    func startObservation() {
        guard !isObserving else { return }
        isObserving = true
        lastError = nil
        observationTask = Task {
            do {
                let deps = try dependencies
                deps.privateModeController.isEnabled = isPrivateMode
                while !Task.isCancelled && isObserving {
                    do {
                        let result = try await deps.observationPipeline.process(event: .periodic)
                        if let summary = result?.summary {
                            lastObservationSummary = DisplaySanitizer.safeSummary(summary)
                        }
                        memories = try deps.memoryRepository.fetchAll(limit: 200)
                        recentObservations = try deps.observationRepository.fetchRecent(limit: 50)
                        episodes = try deps.episodeService.fetchRecent(limit: 30)
                        lastError = nil
                    } catch {
                        lastError = DisplaySanitizer.safeError(error.localizedDescription)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            } catch {
                lastError = DisplaySanitizer.safeError(error.localizedDescription)
            }
        }
        decayTask = Task {
            while !Task.isCancelled && isObserving {
                try? await Task.sleep(for: .seconds(300))
                guard let deps = try? dependencies else { continue }
                try? deps.memoryDecayService.applyDecay(memoryRepository: deps.memoryRepository)
                memories = (try? deps.memoryRepository.fetchAll(limit: 200)) ?? memories
            }
        }
    }

    func pauseObservation() {
        isObserving = false
        observationTask?.cancel()
        decayTask?.cancel()
        observationTask = nil
        decayTask = nil
    }

    func observeCurrentScreen() async {
        do {
            let deps = try dependencies
            let result = try await deps.observationPipeline.process(
                event: .manual(userInitiated: true)
            )
            if let summary = result?.summary {
                lastObservationSummary = DisplaySanitizer.safeSummary(summary)
            }
            memories = try deps.memoryRepository.fetchAll(limit: 200)
            recentObservations = try deps.observationRepository.fetchRecent(limit: 50)
            lastError = nil
        } catch {
            lastError = DisplaySanitizer.safeError(error.localizedDescription)
        }
    }

    func askMemory(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let history = conversationHistoryTurns()
        let userMessage = ChatMessage(role: .user, text: query, timestamp: Date())
        chatMessages.append(userMessage)

        let sessionID: UUID
        do {
            sessionID = try ensureActiveSession(firstUserMessage: query)
            persistChatTurn(sessionID: sessionID, message: userMessage)
        } catch {
            lastError = error.localizedDescription
            sessionID = activeChatSessionID ?? UUID()
        }

        isQuerying = true
        isSearchingWeb = false
        setAgentPhase(.thinking)
        defer { isQuerying = false; isSearchingWeb = false }

        if showMeEnabled {
            await runShowMeGuide(query: query, sessionID: sessionID)
            return
        }

        do {
            let deps = try dependencies
            let agentAnswer: AgentAnswer
            if cloudProcessingEnabled, deps.qwenClient.isConfigured {
                agentAnswer = try await deps.personalAgent.answer(
                    query: query,
                    webSearchEnabled: webSearchEnabled,
                    profile: preferencesStore.profile,
                    agentPreferences: preferencesStore.agentPreferences,
                    conversationHistory: history,
                    lastScreenContext: lastScreenContext,
                    onStatus: AgentStatusReporter.mainActor { [weak self] phase in
                        self?.setAgentPhase(phase)
                    }
                )
            } else {
                setAgentPhase(.retrieving)
                let ranked = try await deps.hybridRetriever.retrieve(query: query)
                agentAnswer = AgentAnswer(
                    response: AssistantResponse.localFallback(query: query, memories: ranked.map(\.memory)),
                    route: .memory,
                    statusText: AgentActivityPhase.retrieving.displayText
                )
            }
            if let screen = agentAnswer.screenContext, !screen.isEmpty {
                lastScreenContext = screen
            }
            assistantResponse = agentAnswer.response
            let cleanText = AnswerSanitizer.sanitize(agentAnswer.response.answer)
            let citations = CitationBuilder.from(response: agentAnswer.response)
            let assistantMessage = ChatMessage(
                role: .assistant,
                text: cleanText,
                citations: citations,
                timestamp: Date()
            )
            chatMessages.append(assistantMessage)
            persistChatTurn(sessionID: sessionID, message: assistantMessage)
            deps.chatLearningService.learn(from: query, route: agentAnswer.route)
        } catch {
            lastError = error.localizedDescription
            let detail = error.localizedDescription
            let fallback = detail.isEmpty
                ? "I couldn't answer that yet. Try rephrasing, or check your Qwen API connection."
                : "Web search failed: \(detail)"
            assistantResponse = AssistantResponse(
                answer: fallback,
                sources: [],
                usedMemoryIDs: [],
                confidence: 0,
                ambiguityNotice: detail
            )
            let assistantMessage = ChatMessage(role: .assistant, text: fallback, timestamp: Date())
            chatMessages.append(assistantMessage)
            persistChatTurn(sessionID: sessionID, message: assistantMessage)
        }
    }

    private func runShowMeGuide(query: String, sessionID: UUID) async {
        setAgentPhase(.guiding)
        do {
            let deps = try dependencies
            deps.activeApplicationService.rememberUserContextBeforeFocusSteal()
            setAgentPhase(.readingScreen)
            let result = try await deps.showMePlanner.plan(query: query)
            if let screen = result.screenContext, !screen.isEmpty {
                lastScreenContext = screen
            }

            let session = ShowMeGuideSession(
                query: query,
                intro: result.plan.intro,
                steps: result.steps
            )
            activeShowMeGuide = session

            let introText = AnswerSanitizer.sanitize(
                """
                \(result.plan.intro)

                Show Me is on — I'll point on your screen. Do each step yourself; I'll advance automatically when I see it done. If you click the wrong thing, I'll suggest a correction.
                """
            )
            let introMessage = ChatMessage(role: .assistant, text: introText, timestamp: Date())
            chatMessages.append(introMessage)
            persistChatTurn(sessionID: sessionID, message: introMessage)

            presentCurrentShowMeStep(appendChat: true, sessionID: sessionID)
        } catch {
            lastError = error.localizedDescription
            let fallback = "I couldn't start Show Me for that. Try again with the window you want visible, or turn Show Me off for a normal answer."
            let assistantMessage = ChatMessage(role: .assistant, text: fallback, timestamp: Date())
            chatMessages.append(assistantMessage)
            persistChatTurn(sessionID: sessionID, message: assistantMessage)
            endShowMeGuide(announce: false)
        }
    }

    func advanceShowMeStep() {
        guard var guide = activeShowMeGuide, !guide.isComplete else { return }
        let next = guide.currentIndex + 1
        if next >= guide.steps.count {
            completeShowMeGuide()
            return
        }
        guide.currentIndex = next
        activeShowMeGuide = guide
        presentCurrentShowMeStep(appendChat: true, sessionID: activeChatSessionID)
    }

    func completeShowMeGuide() {
        stopShowMeWatcher()
        guard activeShowMeGuide != nil else { return }
        ShowMeOverlayController.shared.hide()
        showMeStatusText = nil
        showMeBaseline = nil
        let text = "Nice work — that was the last step. Show Me is done. Ask another question anytime, or leave Show Me on for the next walkthrough."
        let message = ChatMessage(role: .assistant, text: text, timestamp: Date())
        chatMessages.append(message)
        if let sessionID = activeChatSessionID {
            persistChatTurn(sessionID: sessionID, message: message)
        }
        activeShowMeGuide = nil
    }

    func endShowMeGuide(announce: Bool = true) {
        stopShowMeWatcher()
        ShowMeOverlayController.shared.hide()
        activeShowMeGuide = nil
        showMeStatusText = nil
        showMeBaseline = nil
        guard announce else { return }
        let message = ChatMessage(
            role: .assistant,
            text: "Show Me ended. You can turn it back on anytime from the chat footer.",
            timestamp: Date()
        )
        chatMessages.append(message)
        if let sessionID = activeChatSessionID {
            persistChatTurn(sessionID: sessionID, message: message)
        }
    }

    private func presentCurrentShowMeStep(appendChat: Bool, sessionID: UUID?) {
        guard let guide = activeShowMeGuide, let step = guide.currentStep else { return }
        let label = "Step \(guide.progressLabel)"
        ShowMeOverlayController.shared.show(step: step, stepLabel: label, correctionMode: false)
        showMeStatusText = "Watching for your action…"
        refreshShowMeBaselineAndWatch()

        guard appendChat else { return }
        let text = AnswerSanitizer.sanitize(
            """
            \(label): \(step.title)

            \(step.instruction)

            Follow the pointer. I'll move on when this step is done — or tap Next if you need to skip ahead.
            """
        )
        let message = ChatMessage(role: .assistant, text: text, timestamp: Date())
        chatMessages.append(message)
        if let sessionID {
            persistChatTurn(sessionID: sessionID, message: message)
        }
    }

    private func refreshShowMeBaselineAndWatch() {
        stopShowMeWatcher()
        guard let deps = try? dependencies,
              let context = deps.activeApplicationService.currentContext() else {
            return
        }
        let finder = ShowMeTargetFinder()
        showMeBaseline = finder.activitySnapshot(pid: context.pid)
        lastShowMeCorrectionAt = nil
        startShowMeWatcher()
    }

    private func startShowMeWatcher() {
        showMeWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                guard let self, let guide = self.activeShowMeGuide, let step = guide.currentStep else { break }
                await self.pollShowMeProgress(guide: guide, step: step)
                try? await Task.sleep(for: .milliseconds(550))
            }
        }
    }

    private func stopShowMeWatcher() {
        showMeWatchTask?.cancel()
        showMeWatchTask = nil
    }

    private func pollShowMeProgress(guide: ShowMeGuideSession, step: ShowMeResolvedStep) async {
        guard let deps = try? dependencies else { return }
        guard let context = deps.activeApplicationService.currentContext() else { return }

        let finder = ShowMeTargetFinder()

        if let hit = finder.resolve(hints: step.targetHints, regionHint: nil, context: context) {
            var updated = guide
            var updatedStep = step
            updatedStep.targetPoint = hit.point
            updatedStep.targetRect = hit.rect
            if updated.currentIndex < updated.steps.count {
                updated.steps[updated.currentIndex] = updatedStep
                activeShowMeGuide = updated
                ShowMeOverlayController.shared.show(
                    step: updatedStep,
                    stepLabel: "Step \(updated.progressLabel)",
                    correctionMode: false
                )
            }
        }

        let baseline = showMeBaseline ?? finder.activitySnapshot(pid: context.pid)
        let latest = finder.activitySnapshot(pid: context.pid)
        let currentStep = activeShowMeGuide?.currentStep ?? step
        let verdict = finder.evaluateProgress(
            current: currentStep,
            allSteps: guide.steps,
            currentIndex: guide.currentIndex,
            baseline: baseline,
            latest: latest
        )

        switch verdict {
        case .idle:
            showMeStatusText = "Watching for your action…"
        case .stepCompleted:
            showMeStatusText = "Got it — next step"
            let message = ChatMessage(
                role: .assistant,
                text: "Nice — I saw that. Moving to the next step.",
                timestamp: Date()
            )
            chatMessages.append(message)
            if let sessionID = activeChatSessionID {
                persistChatTurn(sessionID: sessionID, message: message)
            }
            advanceShowMeStep()
        case .wrongAction(let correction):
            if let last = lastShowMeCorrectionAt, Date().timeIntervalSince(last) < 4 {
                return
            }
            lastShowMeCorrectionAt = Date()
            showMeStatusText = "Hmm — try again"
            if let current = activeShowMeGuide?.currentStep {
                ShowMeOverlayController.shared.show(
                    step: current,
                    stepLabel: "Correction · Step \(guide.progressLabel)",
                    correctionMode: true
                )
            }
            let message = ChatMessage(
                role: .assistant,
                text: AnswerSanitizer.sanitize("Quick correction: \(correction)"),
                timestamp: Date()
            )
            chatMessages.append(message)
            if let sessionID = activeChatSessionID {
                persistChatTurn(sessionID: sessionID, message: message)
            }
            showMeBaseline = latest
        }
    }

    private func setAgentPhase(_ phase: AgentActivityPhase) {
        agentActivityPhase = phase
        queryStatusText = phase.displayText
        isSearchingWeb = phase == .searching
    }

    func deleteMemory(id: UUID) {
        do {
            let deps = try dependencies
            try deps.memoryRepository.delete(id: id)
            try deps.searchIndex.remove(memoryID: id)
            deps.vectorStore.remove(memoryID: id)
            memories.removeAll { $0.id == id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pinMemory(id: UUID, pinned: Bool) {
        do {
            let deps = try dependencies
            try deps.memoryRepository.setPinned(id: id, pinned: pinned)
            memories = try deps.memoryRepository.fetchAll(limit: 200)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearAllData() {
        do {
            let deps = try dependencies
            try deps.database.clearAll()
            deps.vectorStore.clear()
            memories = []
            recentObservations = []
            episodes = []
            assistantResponse = nil
            chatSessions = []
            activeChatSessionID = nil
            chatMessages = []
            lastScreenContext = nil
            startNewChatSession()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openFloatingAssistant() {
        openChat()
    }

    func openMemoryInspector() {
        openMainApp(section: .memories)
    }

    func seedDemoMemories() async {
        do {
            let deps = try dependencies
            let now = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
            let demo = Memory(
                id: UUID(),
                type: .research,
                title: "Understanding HBM for AI Workloads",
                content: "The article discussed how HBM improves bandwidth but still requires careful placement and reuse to avoid data-movement bottlenecks. KV-cache storage and memory bandwidth are critical for LLM inference.",
                summary: "Explored KV-cache storage, HBM capacity and memory bandwidth for LLM inference.",
                topics: ["storage", "HBM", "KV-cache", "LLM inference"],
                keywords: ["storage", "hbm", "bandwidth", "inference"],
                entities: [MemoryEntity(type: "technology", name: "HBM")],
                sourceApplication: "Safari",
                sourceTitle: "Understanding HBM for AI Workloads",
                sourceURL: "https://example.com/hbm-ai-workloads",
                firstObservedAt: yesterday,
                lastObservedAt: yesterday,
                occurrenceCount: 1,
                importance: 0.82,
                confidence: 0.88,
                sensitivity: 0.05,
                novelty: 0.9,
                attention: 0.8,
                futureUtility: 0.85,
                memoryState: .durable,
                expiresAt: nil,
                isPinned: false,
                isUserCorrected: false,
                embedding: deps.vectorStore.embed(text: "HBM storage bandwidth LLM inference KV-cache"),
                relatedMemoryIDs: [],
                evidenceObservationIDs: [],
                cloudProcessed: false,
                admissionReason: "demo_seed",
                createdAt: yesterday,
                updatedAt: yesterday
            )
            try deps.memoryRepository.save(demo)
            try deps.searchIndex.index(memory: demo)
            if let embedding = demo.embedding {
                deps.vectorStore.upsert(memoryID: demo.id, embedding: embedding)
            }
            memories = try deps.memoryRepository.fetchAll(limit: 200)
            lastObservationSummary = demo.summary
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct PermissionStatus: Equatable {
    var screenRecording = false
    var accessibility = false

    var allGranted: Bool { screenRecording && accessibility }
}

enum ObservationTriggerEvent {
    case periodic
    case manual(userInitiated: Bool)
    case appChanged
    case windowChanged
    case urlChanged
}
