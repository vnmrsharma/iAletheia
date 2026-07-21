import Foundation

final class ActionPlanner {
    private let openAIClient: OpenAIClient
    private let observationPipeline: ObservationPipeline
    private let activeApplicationService: ActiveApplicationService

    init(
        openAIClient: OpenAIClient,
        observationPipeline: ObservationPipeline,
        activeApplicationService: ActiveApplicationService
    ) {
        self.openAIClient = openAIClient
        self.observationPipeline = observationPipeline
        self.activeApplicationService = activeApplicationService
    }

    func plan(query: String, personality: String) async throws -> (
        plan: DraftActionPlan,
        context: ActiveApplicationContext,
        screenContext: String?
    ) {
        try ActionSafetyPolicy.validateRequest(query)
        guard openAIClient.isConfigured else { throw ActionError.unavailable }

        activeApplicationService.rememberUserContextBeforeFocusSteal()
        guard var context = activeApplicationService.currentContext() else { throw ActionError.unavailable }
        context = activeApplicationService.refreshContextForAction(context)
        guard let snapshot = await observationPipeline.captureLiveSnapshot(),
              snapshot.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
            throw ActionError.unavailable
        }
        let generatedPlan = try await openAIClient.generateDraftActionPlan(
            query: query,
            snapshot: snapshot,
            appName: context.applicationName,
            windowTitle: context.windowTitle,
            personality: personality
        )
        let plan = DraftActionPlanNormalizer.normalize(generatedPlan, for: query, snapshot: snapshot)
        try ActionSafetyPolicy.validatePlan(plan)
        return (plan, context, snapshot.contextBlock())
    }
}
