import Foundation

/// Plans step-by-step on-screen guidance from the live window (instructor mode — does not click for the user).
final class ShowMePlanner {
    private let qwenClient: QwenClient
    private let observationPipeline: ObservationPipeline
    private let activeApplicationService: ActiveApplicationService
    private let screenCaptureService: ScreenCaptureService
    private let targetFinder = ShowMeTargetFinder()

    init(
        qwenClient: QwenClient,
        observationPipeline: ObservationPipeline,
        activeApplicationService: ActiveApplicationService,
        screenCaptureService: ScreenCaptureService
    ) {
        self.qwenClient = qwenClient
        self.observationPipeline = observationPipeline
        self.activeApplicationService = activeApplicationService
        self.screenCaptureService = screenCaptureService
    }

    @MainActor
    func plan(query: String) async throws -> (plan: ShowMePlan, steps: [ShowMeResolvedStep], screenContext: String?) {
        activeApplicationService.rememberUserContextBeforeFocusSteal()
        let context = activeApplicationService.currentContext()
        let snapshot = await observationPipeline.captureLiveSnapshot()
        let screenBlock = snapshot?.contextBlock()

        let plan: ShowMePlan
        if qwenClient.isConfigured {
            do {
                plan = try await qwenClient.generateShowMePlan(
                    query: query,
                    snapshot: snapshot,
                    appName: context?.applicationName,
                    windowTitle: context?.windowTitle
                )
            } catch {
                plan = Self.localFallbackPlan(query: query, appName: context?.applicationName)
            }
        } else {
            plan = Self.localFallbackPlan(query: query, appName: context?.applicationName)
        }

        var resolved: [ShowMeResolvedStep] = []
        for step in plan.steps {
            var point: CGPoint?
            var rect: CGRect?
            if let context {
                if let hit = await targetFinder.resolve(
                    hints: step.targetHints,
                    regionHint: step.regionHint,
                    context: context,
                    captureService: screenCaptureService
                ) {
                    point = hit.point
                    rect = hit.rect
                }
            }
            resolved.append(
                ShowMeResolvedStep(
                    id: step.id,
                    title: step.title,
                    instruction: step.instruction,
                    targetHints: step.targetHints,
                    targetPoint: point,
                    targetRect: rect,
                    doneHint: step.doneHint
                )
            )
        }

        return (plan, resolved, screenBlock)
    }

    static func localFallbackPlan(query: String, appName: String?) -> ShowMePlan {
        let app = appName ?? "the current app"
        return ShowMePlan(
            intro: "I'll guide you step by step in \(app). Follow the pointer — I won't click for you.",
            steps: [
                ShowMePlanStep(
                    title: "Look at the top of the window",
                    instruction: "Check the menu bar or ribbon at the top of \(app). Many formatting tools live there.",
                    targetHints: ["Home", "Format", "Edit"],
                    regionHint: "ribbon",
                    doneHint: nil
                ),
                ShowMePlanStep(
                    title: "Search for the control",
                    instruction: "Look for a control related to: \(query). If you see a search icon in the app, try searching for that word.",
                    targetHints: ["Search", "Help"],
                    regionHint: "top",
                    doneHint: nil
                ),
                ShowMePlanStep(
                    title: "Use the control",
                    instruction: "Once you find it, click it yourself to complete the action. Tell me when you're done or press Next if you need another hint.",
                    targetHints: [],
                    regionHint: "center",
                    doneHint: nil
                )
            ]
        )
    }
}
