import Foundation

final class ObservationPipeline {
    private let activeApplicationService: ActiveApplicationService
    private let accessibilityService: AccessibilityService
    private let screenCaptureService: ScreenCaptureService
    private let browserMetadataService: BrowserMetadataService
    private let privacyFilter: PrivacyFilter
    private let memoryExtractionService: MemoryExtractionService
    private let memoryAdmissionEngine: MemoryAdmissionEngine
    private let memoryDeduplicator: MemoryDeduplicator
    private let memoryLinker: MemoryLinker
    private let memoryConsolidator: MemoryConsolidator
    private let smartEntityMemory: SmartEntityMemoryService
    private let observationRepository: ObservationRepository
    private let memoryRepository: MemoryRepository
    private let searchIndex: SearchIndex
    private let vectorStore: VectorStore
    private let episodeService: EpisodeService
    private let fingerprints = ContentFingerprintStore()

    init(
        activeApplicationService: ActiveApplicationService,
        accessibilityService: AccessibilityService,
        screenCaptureService: ScreenCaptureService,
        browserMetadataService: BrowserMetadataService,
        privacyFilter: PrivacyFilter,
        redactionService: RedactionService,
        memoryExtractionService: MemoryExtractionService,
        memoryAdmissionEngine: MemoryAdmissionEngine,
        memoryDeduplicator: MemoryDeduplicator,
        memoryLinker: MemoryLinker,
        memoryConsolidator: MemoryConsolidator,
        smartEntityMemory: SmartEntityMemoryService,
        observationRepository: ObservationRepository,
        memoryRepository: MemoryRepository,
        searchIndex: SearchIndex,
        vectorStore: VectorStore,
        episodeService: EpisodeService
    ) {
        self.activeApplicationService = activeApplicationService
        self.accessibilityService = accessibilityService
        self.screenCaptureService = screenCaptureService
        self.browserMetadataService = browserMetadataService
        self.privacyFilter = privacyFilter
        self.memoryExtractionService = memoryExtractionService
        self.memoryAdmissionEngine = memoryAdmissionEngine
        self.memoryDeduplicator = memoryDeduplicator
        self.memoryLinker = memoryLinker
        self.memoryConsolidator = memoryConsolidator
        self.smartEntityMemory = smartEntityMemory
        self.observationRepository = observationRepository
        self.memoryRepository = memoryRepository
        self.searchIndex = searchIndex
        self.vectorStore = vectorStore
        self.episodeService = episodeService
    }

    func process(event: ObservationTriggerEvent) async throws -> ObservationPipelineResult? {
        guard let context = activeApplicationService.currentContext() else { return nil }

        let browser = browserMetadataService.extract(for: context)
        var extractedText = ""

        if let accessibility = accessibilityService.extract(
            from: context.pid,
            preferredWindowTitle: context.windowTitle
        ) {
            extractedText = accessibility.text
        }

        do {
            if let image = try await screenCaptureService.captureActiveWindowImage(
                for: context.pid,
                windowID: context.windowID,
                windowBounds: context.windowBounds
            ) {
                let ocrText = try await screenCaptureService.ocrText(from: image)
                if ocrText.count > extractedText.count {
                    extractedText = ocrText
                }
            }
        } catch {
            // Continue with accessibility text if screenshot fails.
        }

        let trimmed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30 else { return nil }

        let privacy = privacyFilter.evaluate(
            bundleID: context.bundleID,
            url: browser.url,
            text: trimmed,
            windowTitle: context.windowTitle
        )
        guard privacy.decision != .discard else { return nil }

        let title = browser.pageTitle ?? context.windowTitle ?? context.applicationName
        let fingerprint = ContentFingerprintStore.make(title: title, url: browser.url, text: privacy.redactedText)
        if fingerprints.isDuplicate(fingerprint: fingerprint) {
            return nil
        }

        let preliminaryScore = memoryAdmissionEngine.preliminaryScore(
            attention: 0.8,
            visibleDuration: event.userInitiated ? 120 : AdmissionConfig.observationCooldownSeconds,
            interaction: InteractionSignals(keyboardActivity: event.userInitiated),
            sourceValue: browser.url == nil ? 0.7 : 0.85,
            changeSignificance: event.changeSignificance,
            sensitivity: privacy.sensitivityScore
        )
        guard preliminaryScore >= AdmissionConfig.preRejectThreshold else {
            try observationRepository.save(record: ProcessedObservationRecord(
                id: UUID(),
                capturedAt: Date(),
                applicationName: context.applicationName,
                windowTitle: title,
                sourceURL: browser.url,
                redactedText: String(privacy.redactedText.prefix(500)),
                sensitivityScore: privacy.sensitivityScore,
                admissionScore: preliminaryScore,
                decision: "rejected_preliminary"
            ))
            fingerprints.markSeen(fingerprint)
            return nil
        }

        let processed = ProcessedObservation(
            id: UUID(),
            sourceObservationID: UUID(),
            capturedAt: Date(),
            applicationName: context.applicationName,
            applicationBundleID: context.bundleID,
            title: title,
            url: browser.url,
            redactedText: privacy.redactedText,
            sensitivityScore: privacy.sensitivityScore,
            attentionScore: 0.8,
            preliminaryUtilityScore: preliminaryScore,
            cloudProcessingAllowed: privacy.decision == .allow
        )

        let candidates = memoryExtractionService.extractLocal(from: processed, attentionScore: 0.8)
        guard !candidates.isEmpty else { return nil }

        var savedMemoryID: UUID?
        var resultSummary: String?
        for localCandidate in candidates {
            let existing = try memoryRepository.fetchAll(limit: 200)
            let preliminaryDeduplication = memoryDeduplicator.operation(
                candidate: localCandidate,
                existing: existing,
                vectorStore: vectorStore
            )
            let initialStoreScore = memoryAdmissionEngine.finalStoreScore(
                candidate: localCandidate,
                sensitivity: processed.sensitivityScore,
                redundancy: preliminaryDeduplication.2
            )
            let initialAdmission = memoryAdmissionEngine.decision(
                for: initialStoreScore,
                sensitivity: processed.sensitivityScore
            )
            guard initialAdmission.0 != nil else {
                try observationRepository.save(record: ProcessedObservationRecord(
                    id: processed.id,
                    capturedAt: processed.capturedAt,
                    applicationName: processed.applicationName,
                    windowTitle: processed.title,
                    sourceURL: processed.url,
                    redactedText: String(processed.redactedText.prefix(500)),
                    sensitivityScore: processed.sensitivityScore,
                    admissionScore: initialStoreScore,
                    decision: initialAdmission.1
                ))
                continue
            }

            var candidate = localCandidate
            var cloudProcessed = false
            if initialStoreScore >= AdmissionConfig.storeDurableThreshold || event.userInitiated {
                let enrichment = await memoryExtractionService.enrich(
                    candidate: localCandidate,
                    from: processed,
                    userInitiated: event.userInitiated
                )
                candidate = enrichment.candidate
                cloudProcessed = enrichment.cloudProcessed
            }

            let basic = memoryDeduplicator.operation(
                candidate: candidate,
                existing: existing,
                vectorStore: vectorStore
            )
            let storeScore = memoryAdmissionEngine.finalStoreScore(
                candidate: candidate,
                sensitivity: processed.sensitivityScore,
                redundancy: basic.2
            )
            let admission = memoryAdmissionEngine.decision(for: storeScore, sensitivity: processed.sensitivityScore)
            guard let memoryState = admission.0 else { continue }

            let decision = smartEntityMemory.decide(
                candidate: candidate,
                observation: processed,
                basicOperation: basic.0,
                basicTarget: basic.1,
                basicSimilarity: basic.2,
                existing: existing,
                vectorStore: vectorStore
            )
            let embedding = vectorStore.embed(text: candidate.title + " " + candidate.summary)
            let now = Date()

            let memory: Memory
            switch decision.operation {
            case .update, .consolidate:
                guard var existingMemory = decision.targetMemory else { continue }
                smartEntityMemory.applyMerge(
                    decision: decision,
                    candidate: candidate,
                    existingMemory: &existingMemory,
                    embedding: embedding,
                    now: now
                )
                existingMemory.cloudProcessed = existingMemory.cloudProcessed || cloudProcessed
                memory = existingMemory
            default:
                memory = Memory(
                    id: UUID(),
                    type: candidate.type,
                    title: candidate.title,
                    content: candidate.content,
                    summary: decision.unifiedSummary ?? candidate.summary,
                    topics: candidate.topics,
                    keywords: candidate.keywords,
                    entities: decision.mergedEntities,
                    sourceApplication: processed.applicationName,
                    sourceTitle: candidate.sourceTitle,
                    sourceURL: candidate.sourceURL,
                    firstObservedAt: now,
                    lastObservedAt: now,
                    occurrenceCount: 1,
                    importance: candidate.suggestedImportance,
                    confidence: candidate.suggestedConfidence,
                    sensitivity: processed.sensitivityScore,
                    novelty: 1.0,
                    attention: 0.8,
                    futureUtility: candidate.futureUtility,
                    memoryState: memoryState,
                    expiresAt: nil,
                    isPinned: false,
                    isUserCorrected: false,
                    embedding: embedding,
                    relatedMemoryIDs: [],
                    evidenceObservationIDs: [processed.sourceObservationID],
                    cloudProcessed: cloudProcessed,
                    admissionReason: decision.isHomonym ? "homonym_entity" : admission.1,
                    createdAt: now,
                    updatedAt: now
                )
            }

            try memoryRepository.save(memory)
            try searchIndex.index(memory: memory)
            vectorStore.upsert(memoryID: memory.id, embedding: embedding)

            if let relation = decision.relation, let target = decision.targetMemory, target.id != memory.id {
                try memoryLinker.link(
                    sourceID: memory.id,
                    targetID: target.id,
                    relation: relation,
                    strength: decision.similarity,
                    database: memoryRepository.database
                )
            } else if basic.2 >= 0.65, let near = basic.1, near.id != memory.id, decision.operation == .add {
                try memoryLinker.link(
                    sourceID: memory.id,
                    targetID: near.id,
                    relation: "related",
                    strength: basic.2,
                    database: memoryRepository.database
                )
            }

            try episodeService.attach(
                observationID: processed.sourceObservationID,
                memoryID: memory.id,
                app: processed.applicationName,
                topicHint: candidate.topics.first
            )
            savedMemoryID = memory.id
            resultSummary = candidate.summary

            try observationRepository.save(record: ProcessedObservationRecord(
                id: processed.id,
                capturedAt: processed.capturedAt,
                applicationName: processed.applicationName,
                windowTitle: processed.title,
                sourceURL: processed.url,
                redactedText: String(processed.redactedText.prefix(500)),
                sensitivityScore: processed.sensitivityScore,
                admissionScore: storeScore,
                decision: decision.operation == .add ? "stored_new" : "updated_existing"
            ))
        }

        fingerprints.markSeen(fingerprint)
        guard savedMemoryID != nil else { return nil }
        return ObservationPipelineResult(summary: resultSummary, memoryID: savedMemoryID)
    }

    /// Fast live read of the active window for "what's on my screen now" queries.
    func captureLiveSnapshot() async -> LiveScreenSnapshot? {
        // Hide the floating chat/owl so it does not cover Cursor during capture/OCR.
        await OwlWidgetController.shared.withPanelHiddenForCapture {
            await self.captureLiveSnapshotUnobstructed()
        }
    }

    private func captureLiveSnapshotUnobstructed() async -> LiveScreenSnapshot? {
        // Refresh sticky target once more in case chat already held focus.
        activeApplicationService.rememberUserContextBeforeFocusSteal()
        guard let context = activeApplicationService.currentContext() else { return nil }

        let browser = browserMetadataService.extract(for: context)
        let isBrowser = browserMetadataService.isBrowser(bundleID: context.bundleID)

        var accessibilityText = ""
        if let accessibility = accessibilityService.extract(
            from: context.pid,
            preferredWindowTitle: context.windowTitle,
            maxCharacters: 16000
        ) {
            accessibilityText = accessibility.text
            if let selected = accessibility.selectedText, selected.count > 40 {
                accessibilityText = selected + "\n\n" + accessibilityText
            }
        }

        var ocrText = ""
        if let image = try? await screenCaptureService.captureActiveWindowImage(
            for: context.pid,
            windowID: context.windowID,
            windowBounds: context.windowBounds
        ) {
            // Browsers (Gmail etc.) often expose thin AX trees — prefer accurate OCR of THIS window.
            if isBrowser {
                ocrText = (try? await screenCaptureService.ocrText(from: image)) ?? ""
            } else {
                ocrText = (try? await screenCaptureService.ocrTextForLiveScreen(from: image)) ?? ""
            }
        }

        // If still thin, capture the display that contains the active window (multi-monitor safe).
        if ocrText.count < 120, accessibilityText.count < 120,
           let displayImage = try? await screenCaptureService.captureMainDisplayImage(
            containing: context.windowBounds
           ) {
            let displayOCR = (try? await screenCaptureService.ocrText(from: displayImage)) ?? ""
            if displayOCR.count > ocrText.count {
                ocrText = displayOCR
            }
        }

        ocrText = filterOCRAgainstWindowContext(
            ocr: ocrText,
            windowTitle: context.windowTitle,
            url: browser.url
        )

        let extractedText = mergeCapturedText(
            accessibility: accessibilityText,
            ocr: ocrText,
            preferAccessibility: !isBrowser
        )
        let title = browser.pageTitle ?? context.windowTitle ?? context.applicationName
        let trimmed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)

        var visible = trimmed
        if visible.count < 40 {
            var lines = [
                "Active application: \(context.applicationName)",
                "Window title: \(title)"
            ]
            if let url = browser.url { lines.append("URL: \(url)") }
            if !trimmed.isEmpty {
                lines.append("Partial visible text:")
                lines.append(trimmed)
            }
            visible = lines.joined(separator: "\n")
        }

        // Live chat path: keep readable content; only strip secrets/keys/cards.
        let redacted = RedactionService().redact(visible)
        _ = privacyFilter.evaluate(
            bundleID: context.bundleID,
            url: browser.url,
            text: redacted,
            windowTitle: context.windowTitle
        )

        return LiveScreenSnapshot(
            applicationName: context.applicationName,
            bundleID: context.bundleID,
            windowTitle: title,
            url: browser.url,
            visibleText: String(redacted.prefix(12000)),
            capturedAt: Date()
        )
    }

    /// Drop OCR that clearly belongs to a different tab/window than the active title/URL.
    private func filterOCRAgainstWindowContext(ocr: String, windowTitle: String?, url: String?) -> String {
        let text = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        let title = (windowTitle ?? "").lowercased()
        let urlLower = (url ?? "").lowercased()
        let ocrLower = text.lowercased()

        let looksLikeMail = title.contains("gmail") || title.contains("mail") || title.contains("inbox")
            || urlLower.contains("mail.google") || urlLower.contains("outlook") || urlLower.contains("mail.")
        let ocrLooksLikeGitHub = ocrLower.contains("github.com") || ocrLower.contains("create a new repository")
            || ocrLower.contains("repository name") || ocrLower.contains("quick setup")

        if looksLikeMail && ocrLooksLikeGitHub {
            // Wrong window was OCR'd — discard conflicting body so the model uses title/AX instead.
            return ""
        }

        let looksLikeGitHub = title.contains("github") || urlLower.contains("github.com")
        let ocrLooksLikeMail = ocrLower.contains("mail.google") || ocrLower.contains("inbox")
            || ocrLower.contains("compose") && ocrLower.contains("gmail")
        if looksLikeGitHub && ocrLooksLikeMail && !title.contains("mail") {
            return ""
        }

        return text
    }

    private func mergeCapturedText(accessibility: String, ocr: String, preferAccessibility: Bool) -> String {
        let a = accessibility.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return o }
        if o.isEmpty { return a }

        // Code editors: accessibility text is far more trustworthy than OCR (OCR invents "typos").
        if preferAccessibility, a.count >= 180 {
            return """
            [Accessibility — authoritative for code]
            \(a)
            """
        }

        if a.count >= o.count, a.contains(String(o.prefix(min(80, o.count)))) { return a }
        if o.count >= a.count, o.contains(String(a.prefix(min(80, a.count)))) {
            return """
            [OCR — may contain character recognition noise; do not treat garbles as typos]
            \(o)
            """
        }

        // Browsers: OCR often has the email body AX misses.
        return """
        [Accessibility]
        \(a)

        [OCR — may contain character recognition noise; do not treat garbles as typos]
        \(o)
        """
    }
}
