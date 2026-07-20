import Foundation

struct InteractionSignals: Codable, Equatable {
    var scrollCount: Int = 0
    var keyboardActivity: Bool = false
    var textWasSelected: Bool = false
    var contentWasCopied: Bool = false
    var pageWasRevisited: Bool = false
}

struct RawObservation: Identifiable, Codable, Equatable {
    let id: UUID
    let capturedAt: Date
    let applicationBundleID: String
    let applicationName: String
    let windowTitle: String?
    let browserURL: String?
    let browserPageTitle: String?
    let extractedText: String
    let selectedText: String?
    let screenChangeScore: Double
    let activeDurationSeconds: Double
    let interactionSignals: InteractionSignals
    let textSource: TextSource

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        applicationBundleID: String,
        applicationName: String,
        windowTitle: String?,
        browserURL: String?,
        browserPageTitle: String?,
        extractedText: String,
        selectedText: String?,
        screenChangeScore: Double,
        activeDurationSeconds: Double,
        interactionSignals: InteractionSignals,
        textSource: TextSource
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.browserPageTitle = browserPageTitle
        self.extractedText = extractedText
        self.selectedText = selectedText
        self.screenChangeScore = screenChangeScore
        self.activeDurationSeconds = activeDurationSeconds
        self.interactionSignals = interactionSignals
        self.textSource = textSource
    }
}

enum TextSource: String, Codable {
    case accessibility
    case ocr
    case hybrid
}

struct ProcessedObservation: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceObservationID: UUID
    let capturedAt: Date
    let applicationName: String
    let applicationBundleID: String
    let title: String?
    let url: String?
    let redactedText: String
    let sensitivityScore: Double
    let attentionScore: Double
    let preliminaryUtilityScore: Double
    let cloudProcessingAllowed: Bool
}

struct LiveScreenSnapshot: Equatable {
    let applicationName: String
    let bundleID: String
    let windowTitle: String?
    let url: String?
    let visibleText: String
    let capturedAt: Date

    func contextBlock() -> String {
        var lines: [String] = ["Active app: \(applicationName)"]
        if let windowTitle, !windowTitle.isEmpty { lines.append("Window/tab title: \(windowTitle)") }
        if let url, !url.isEmpty { lines.append("URL: \(url)") }
        lines.append("Captured: \(capturedAt.formatted(date: .omitted, time: .shortened))")
        lines.append("")
        lines.append("""
        IMPORTANT about visible text:
        - The window title and URL identify the window the user was working in (sticky target while chat has focus; may be on another Mission Control Space).
        - Trust that title/URL over conflicting body text from a different window.
        - Text may come from accessibility APIs and/or OCR of that same window.
        - OCR often misreads characters (especially in code comments). Treat garbled fragments as capture noise, NOT as typos in the user's real file.
        - If body text clearly belongs to a different site than the title/URL (e.g. title is Gmail but body looks like GitHub), ignore the mismatched body and use the title/URL plus any coherent matching content.
        - Prefer coherent, dictionary-like words and valid code identifiers. Do not invent spelling mistakes.
        """)
        lines.append("")
        lines.append("Visible content:")
        lines.append(visibleText)
        return lines.joined(separator: "\n")
    }
}

struct ProcessedObservationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let capturedAt: Date
    let applicationName: String
    let windowTitle: String?
    let sourceURL: String?
    let redactedText: String
    let sensitivityScore: Double
    let admissionScore: Double
    let decision: String
}

struct MemoryEntity: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let type: String
    let name: String
    let normalizedName: String
    let context: String?

    init(id: UUID = UUID(), type: String, name: String, context: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = context
    }
}

enum MemoryType: String, Codable, CaseIterable {
    case research
    case webpage
    case communicationPreference
    case person
    case project
    case decision
    case schedule
    case task
    case deadline
    case workflow
    case userPreference
    case document
    case code
    case temporaryContext
}

enum MemoryState: String, Codable, CaseIterable {
    case temporary
    case durable
    case consolidated
    case superseded
    case expired
    case deleted
}

struct MemoryCandidate: Identifiable, Codable, Equatable {
    let id: UUID
    let type: MemoryType
    let title: String
    let content: String
    let summary: String
    let topics: [String]
    let keywords: [String]
    let entities: [MemoryEntity]
    let suggestedImportance: Double
    let suggestedConfidence: Double
    let suggestedExpiry: Date?
    let sourceURL: String?
    let sourceTitle: String?
    let futureUtility: Double
    let actionability: Double
    let explicitness: Double
    let transience: Double
}

struct Memory: Identifiable, Codable, Equatable {
    let id: UUID
    var type: MemoryType
    var title: String
    var content: String
    var summary: String
    var topics: [String]
    var keywords: [String]
    var entities: [MemoryEntity]
    var sourceApplication: String
    var sourceTitle: String?
    var sourceURL: String?
    var firstObservedAt: Date
    var lastObservedAt: Date
    var occurrenceCount: Int
    var importance: Double
    var confidence: Double
    var sensitivity: Double
    var novelty: Double
    var attention: Double
    var futureUtility: Double
    var memoryState: MemoryState
    var expiresAt: Date?
    var isPinned: Bool
    var isUserCorrected: Bool
    var embedding: [Float]?
    var relatedMemoryIDs: [UUID]
    var evidenceObservationIDs: [UUID]
    var cloudProcessed: Bool
    var admissionReason: String?
    var createdAt: Date
    var updatedAt: Date
}

struct Episode: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var dominantApp: String
    var topicHint: String?
    var observationIDs: [UUID]
    var memoryIDs: [UUID]
}

struct SearchIntent: Codable, Equatable {
    var intent: String
    var semanticQuery: String
    var keywords: [String]
    var relatedConcepts: [String]
    var timeRange: TimeRangeFilter?
    var sourceTypes: [String]
    var requestedOutput: [String]
}

struct TimeRangeFilter: Codable, Equatable {
    enum RangeType: String, Codable { case relative, absolute }
    var type: RangeType
    var relativeValue: String?
    var start: Date?
    var end: Date?
}

struct RankedMemory: Equatable {
    let memory: Memory
    let score: Double
}

struct ResponseSource: Codable, Equatable, Identifiable {
    var id: String { title + (url ?? "") + observedAt.description }
    let title: String
    let url: String?
    let observedAt: Date
    let applicationName: String
}

struct AssistantResponse: Codable, Equatable {
    let answer: String
    let sources: [ResponseSource]
    let webSources: [WebSearchResult]
    let usedMemoryIDs: [UUID]
    let confidence: Double
    let ambiguityNotice: String?
    let usedWebSearch: Bool
    let route: AnswerRoute

    init(
        answer: String,
        sources: [ResponseSource],
        webSources: [WebSearchResult] = [],
        usedMemoryIDs: [UUID],
        confidence: Double,
        ambiguityNotice: String?,
        usedWebSearch: Bool = false,
        route: AnswerRoute = .direct
    ) {
        self.answer = answer
        self.sources = sources
        self.webSources = webSources
        self.usedMemoryIDs = usedMemoryIDs
        self.confidence = confidence
        self.ambiguityNotice = ambiguityNotice
        self.usedWebSearch = usedWebSearch
        self.route = route
    }

    static func localFallback(query: String, memories: [Memory]) -> AssistantResponse {
        guard !memories.isEmpty else {
            return AssistantResponse(
                answer: "I don't have a personal memory for that yet, and web search needs Qwen Cloud to be configured. Keep working — I'll learn as you browse and read.",
                sources: [],
                usedMemoryIDs: [],
                confidence: 0.2,
                ambiguityNotice: "Cloud reasoning is disabled or unavailable."
            )
        }
        let top = Array(memories.prefix(3))
        let answer = top.enumerated().map { index, memory in
            "\(memory.summary) [\(index + 1)]"
        }.joined(separator: " ")
        return AssistantResponse(
            answer: answer,
            sources: top.map {
                ResponseSource(
                    title: $0.sourceTitle ?? $0.title,
                    url: $0.sourceURL,
                    observedAt: $0.lastObservedAt,
                    applicationName: $0.sourceApplication
                )
            },
            usedMemoryIDs: top.map(\.id),
            confidence: 0.65,
            ambiguityNotice: cloudNotice(),
            usedWebSearch: false
        )
    }

    private static func cloudNotice() -> String? {
        "Generated locally from retrieved memories without Qwen Cloud."
    }
}

struct ObservationPipelineResult {
    let summary: String?
    let memoryID: UUID?
}

enum MemoryOperation: String {
    case add
    case update
    case consolidate
    case reject
}

struct AdmissionConfig {
    static let preRejectThreshold = 0.35
    static let preWorkingThreshold = 0.55
    static let storeDurableThreshold = 0.68
    static let storeTemporaryThreshold = 0.48
    static let sensitivityRejectThreshold = 0.80
    static let observationCooldownSeconds: TimeInterval = 20
}
