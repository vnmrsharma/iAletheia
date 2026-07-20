import Foundation

@MainActor
final class DependencyContainer {
    let database: Database
    let observationRepository: ObservationRepository
    let memoryRepository: MemoryRepository
    let exclusionRepository: ExclusionRepository

    let activeApplicationService: ActiveApplicationService
    let accessibilityService: AccessibilityService
    let screenCaptureService: ScreenCaptureService
    let browserMetadataService: BrowserMetadataService
    let observationScheduler: ObservationScheduler

    let privacyFilter: PrivacyFilter
    let redactionService: RedactionService
    let privateModeController: PrivateModeController

    let memoryExtractor: LocalMemoryExtractor
    let memoryAdmissionEngine: MemoryAdmissionEngine
    let memoryDeduplicator: MemoryDeduplicator
    let memoryConsolidator: MemoryConsolidator
    let memoryLinker: MemoryLinker
    let memoryDecayService: MemoryDecayService
    let smartEntityMemory: SmartEntityMemoryService
    let chatLearningService: ChatLearningService
    let chatHistoryRepository: ChatHistoryRepository
    let observationPipeline: ObservationPipeline

    let vectorStore: VectorStore
    let searchIndex: SearchIndex
    let hybridRetriever: HybridRetriever
    let queryInterpreter: QueryInterpreter

    let keychainService: KeychainService
    let qwenClient: QwenClient
    let webSearchService: WebSearchService
    let personalAgent: PersonalAgent
    let showMePlanner: ShowMePlanner

    let episodeService: EpisodeService

    init() throws {
        database = try Database()
        observationRepository = ObservationRepository(database: database)
        memoryRepository = MemoryRepository(database: database)
        exclusionRepository = ExclusionRepository(database: database)

        activeApplicationService = ActiveApplicationService()
        accessibilityService = AccessibilityService()
        screenCaptureService = ScreenCaptureService()
        browserMetadataService = BrowserMetadataService()
        observationScheduler = ObservationScheduler()

        privacyFilter = PrivacyFilter(exclusionRepository: exclusionRepository)
        redactionService = RedactionService()
        privateModeController = PrivateModeController()

        memoryExtractor = LocalMemoryExtractor()
        memoryAdmissionEngine = MemoryAdmissionEngine()
        memoryDeduplicator = MemoryDeduplicator()
        memoryConsolidator = MemoryConsolidator()
        memoryLinker = MemoryLinker()
        memoryDecayService = MemoryDecayService()
        episodeService = EpisodeService(database: database)

        vectorStore = VectorStore()
        searchIndex = SearchIndex(database: database)
        queryInterpreter = QueryInterpreter()
        hybridRetriever = HybridRetriever(
            memoryRepository: memoryRepository,
            searchIndex: searchIndex,
            vectorStore: vectorStore,
            queryInterpreter: queryInterpreter
        )

        keychainService = KeychainService()
        qwenClient = QwenClient(keychainService: keychainService)
        smartEntityMemory = SmartEntityMemoryService(
            memoryRepository: memoryRepository,
            memoryLinker: memoryLinker,
            memoryConsolidator: memoryConsolidator,
            qwenClient: qwenClient
        )
        chatLearningService = ChatLearningService(memoryRepository: memoryRepository)
        chatHistoryRepository = ChatHistoryRepository(database: database)

        let memoryExtractionService = MemoryExtractionService(
            localExtractor: memoryExtractor,
            qwenClient: qwenClient
        )
        webSearchService = WebSearchService()
        observationPipeline = ObservationPipeline(
            activeApplicationService: activeApplicationService,
            accessibilityService: accessibilityService,
            screenCaptureService: screenCaptureService,
            browserMetadataService: browserMetadataService,
            privacyFilter: privacyFilter,
            redactionService: redactionService,
            memoryExtractionService: memoryExtractionService,
            memoryAdmissionEngine: memoryAdmissionEngine,
            memoryDeduplicator: memoryDeduplicator,
            memoryLinker: memoryLinker,
            memoryConsolidator: memoryConsolidator,
            smartEntityMemory: smartEntityMemory,
            observationRepository: observationRepository,
            memoryRepository: memoryRepository,
            searchIndex: searchIndex,
            vectorStore: vectorStore,
            episodeService: episodeService
        )
        personalAgent = PersonalAgent(
            qwenClient: qwenClient,
            webSearchService: webSearchService,
            hybridRetriever: hybridRetriever,
            chatLearningService: chatLearningService,
            observationPipeline: observationPipeline
        )
        showMePlanner = ShowMePlanner(
            qwenClient: qwenClient,
            observationPipeline: observationPipeline,
            activeApplicationService: activeApplicationService
        )
    }
}
