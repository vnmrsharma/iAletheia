import Foundation
import XCTest
@testable import iAletheia

final class MemoryAdmissionEngineTests: XCTestCase {
    func testPreliminaryScoreRejectsSensitiveContent() {
        let engine = MemoryAdmissionEngine()
        let score = engine.preliminaryScore(
            attention: 0.8,
            visibleDuration: 120,
            interaction: InteractionSignals(textWasSelected: true),
            sourceValue: 0.8,
            changeSignificance: 0.9,
            sensitivity: 0.9
        )
        XCTAssertLessThan(score, AdmissionConfig.preRejectThreshold)
    }

    func testFinalDecisionCreatesTemporaryMemory() {
        let engine = MemoryAdmissionEngine()
        let candidate = MemoryCandidate(
            id: UUID(),
            type: .webpage,
            title: "Test",
            content: "Body",
            summary: "Summary",
            topics: [],
            keywords: [],
            entities: [],
            suggestedImportance: 0.5,
            suggestedConfidence: 0.6,
            suggestedExpiry: nil,
            sourceURL: nil,
            sourceTitle: nil,
            futureUtility: 0.5,
            actionability: 0.4,
            explicitness: 0.4,
            transience: 0.5
        )
        let score = engine.finalStoreScore(candidate: candidate, sensitivity: 0.1, redundancy: 0.2)
        let (state, _) = engine.decision(for: score, sensitivity: 0.1)
        XCTAssertNotNil(state)
    }
}

final class PrivacyFilterTests: XCTestCase {
    func testPasswordLikeContentIsDiscarded() {
        let db = try! Database(path: FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db"))
        let filter = PrivacyFilter(exclusionRepository: ExclusionRepository(database: db))
        let result = filter.evaluate(
            bundleID: "com.example.app",
            url: nil,
            text: "password: hunter2",
            windowTitle: "Sign in"
        )
        XCTAssertEqual(result.decision, .discard)
    }
}

final class HybridRetrieverTests: XCTestCase {
    func testRelativeYesterdayParsing() {
        let interpreter = QueryInterpreter()
        let range = interpreter.parseRelativeTime(query: "What was I researching yesterday about storage?")
        XCTAssertNotNil(range?.start)
        XCTAssertNotNil(range?.end)
    }
}

final class OpenAIResponseParserTests: XCTestCase {
    func testRouteRequestUsesResponsesAPIAndStrictSchema() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        var capturedRequest: URLRequest?
        var capturedBody: Data?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
            let responseObject: [String: Any] = [
                "model": "gpt-5.6-luna",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "{\"route\":\"direct\",\"search_query\":null,\"confidence\":0.9,\"reason\":\"general_knowledge\"}"
                    ]]
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: responseObject)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockURLProtocol.handler = nil }

        let client = OpenAIClient(
            keychainService: KeychainService(),
            session: session,
            configuration: {
                OpenAIConfiguration(
                    apiKey: "test-key",
                    baseURL: "https://api.openai.com/v1",
                    reasoningModel: "gpt-5.6-sol",
                    utilityModel: "gpt-5.6-luna",
                    memoryEnrichmentCooldownSeconds: 300
                )
            }
        )

        let route = try await client.classifyRoute(query: "Explain a closure", webSearchEnabled: true)
        XCTAssertEqual(route?.route, .direct)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let bodyData = try XCTUnwrap(capturedBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNotNil(body["safety_identifier"] as? String)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testParsesResponsesAPITextUsageAndWebCitations() throws {
        let payload = """
        {
          "model": "gpt-5.6-sol",
          "output": [{
            "type": "message",
            "content": [{
              "type": "output_text",
              "text": "A current answer.",
              "annotations": [{
                "type": "url_citation",
                "url": "https://example.com/source",
                "title": "Example source",
                "start_index": 0,
                "end_index": 5
              }]
            }]
          }],
          "usage": {"input_tokens": 120, "output_tokens": 30}
        }
        """

        let result = try OpenAIResponseParser.parse(data: Data(payload.utf8))

        XCTAssertEqual(result.text, "A current answer.")
        XCTAssertEqual(result.model, "gpt-5.6-sol")
        XCTAssertEqual(result.inputTokens, 120)
        XCTAssertEqual(result.outputTokens, 30)
        XCTAssertEqual(result.webResults, [
            WebSearchResult(title: "Example source", url: "https://example.com/source", snippet: "")
        ])
    }

    func testDeduplicatesCitationAndSearchSourceMetadata() throws {
        let payload = """
        {
          "output": [
            {
              "type": "web_search_call",
              "action": {"sources": [{"url": "https://example.com", "title": "Example"}]}
            },
            {
              "type": "message",
              "content": [{
                "type": "output_text",
                "text": "Answer",
                "annotations": [{"type": "url_citation", "url": "https://example.com", "title": "Example"}]
              }]
            }
          ]
        }
        """

        let result = try OpenAIResponseParser.parse(data: Data(payload.utf8))
        XCTAssertEqual(result.webResults.count, 1)
    }
}

final class ActionSafetyPolicyTests: XCTestCase {
    func testGridVisionTargetMapsTopLeftCellToCocoaCoordinates() {
        let target = GridVisionClickTarget(
            found: true,
            targetLabel: "Reply",
            gridRow: 0,
            gridColumn: 0,
            cellX: 0.5,
            cellY: 0.5,
            confidence: 0.9,
            reasoning: "Visible Reply button"
        )
        let point = target.cocoaPoint(
            in: CGRect(x: 100, y: 200, width: 1200, height: 800),
            grid: .actionGrid
        )
        XCTAssertNotNil(point)
        XCTAssertEqual(point!.x, 150, accuracy: 0.001)
        XCTAssertEqual(point!.y, 950, accuracy: 0.001)
    }

    func testGridVisionTargetRejectsOutOfRangeCell() {
        let target = GridVisionClickTarget(
            found: true,
            targetLabel: "Reply",
            gridRow: 8,
            gridColumn: 0,
            cellX: 0.5,
            cellY: 0.5,
            confidence: 0.9,
            reasoning: "Invalid row"
        )
        XCTAssertNil(target.cocoaPoint(in: CGRect(x: 0, y: 0, width: 1200, height: 800), grid: .actionGrid))
    }

    func testAllowsDraftRequestWithExplicitNoSendInstruction() {
        XCTAssertNoThrow(
            try ActionSafetyPolicy.validateRequest(
                "Draft a response to this email but do not click Send"
            )
        )
    }

    func testRejectsRequestThatAsksToSend() {
        XCTAssertThrowsError(
            try ActionSafetyPolicy.validateRequest("Draft a response and send it")
        )
    }

    func testAcceptsReplyThenTypePlan() {
        let plan = DraftActionPlan(
            summary: "Draft a reply without sending",
            steps: [
                DraftActionStep(kind: .click, title: "Open reply editor", targetHints: ["Reply"], text: nil),
                DraftActionStep(kind: .typeText, title: "Type draft", targetHints: [], text: "Thanks for the update.")
            ]
        )
        XCTAssertNoThrow(try ActionSafetyPolicy.validatePlan(plan))
    }

    func testRejectsPlanTargetingSend() {
        let plan = DraftActionPlan(
            summary: "Unsafe plan",
            steps: [
                DraftActionStep(kind: .click, title: "Send reply", targetHints: ["Send"], text: nil),
                DraftActionStep(kind: .typeText, title: "Type draft", targetHints: [], text: "Hello")
            ]
        )
        XCTAssertThrowsError(try ActionSafetyPolicy.validatePlan(plan))
    }

    func testNormalizerOpensReplyBeforeTypingOnReadOnlyEmail() {
        let generated = DraftActionPlan(
            summary: "Draft a reply",
            steps: [
                DraftActionStep(
                    kind: .typeText,
                    title: "Type the reply",
                    targetHints: ["Message body"],
                    text: "This is interesting. I would like to know more."
                )
            ]
        )
        let snapshot = LiveScreenSnapshot(
            applicationName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Mail - Outlook",
            url: "https://outlook.cloud.microsoft/mail/inbox/id/example",
            visibleText: "Inbox Archive Reply Reply all Forward Today's email content",
            capturedAt: Date()
        )

        let normalized = DraftActionPlanNormalizer.normalize(
            generated,
            for: "Draft a quick reply to this email",
            snapshot: snapshot
        )

        XCTAssertEqual(normalized.steps.map(\.kind), [.click, .typeText])
        XCTAssertEqual(normalized.steps[0].targetHints, ["Reply"])
        XCTAssertTrue(normalized.steps[1].targetHints.isEmpty)
        XCTAssertNoThrow(try ActionSafetyPolicy.validatePlan(normalized))
    }

    func testNormalizerDoesNotReopenReplyWhenComposerIsVisible() {
        let generated = DraftActionPlan(
            summary: "Draft a reply",
            steps: [
                DraftActionStep(
                    kind: .typeText,
                    title: "Type the reply",
                    targetHints: ["Message body"],
                    text: "Thanks for the update."
                )
            ]
        )
        let snapshot = LiveScreenSnapshot(
            applicationName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Mail - Outlook",
            url: "https://outlook.cloud.microsoft/mail/inbox/id/example",
            visibleText: "Reply Send Discard Bcc Message body",
            capturedAt: Date()
        )

        let normalized = DraftActionPlanNormalizer.normalize(
            generated,
            for: "Draft a reply",
            snapshot: snapshot
        )

        XCTAssertEqual(normalized, generated)
    }

    func testNormalizerSkipsReplyForGmailInlineComposerWithSendAndSignature() {
        let generated = DraftActionPlan(
            summary: "Draft a reply",
            steps: [
                DraftActionStep(
                    kind: .click,
                    title: "Open reply",
                    targetHints: ["Reply"],
                    text: nil
                ),
                DraftActionStep(
                    kind: .typeText,
                    title: "Type the reply",
                    targetHints: [],
                    text: "Thanks for the update."
                )
            ]
        )
        let snapshot = LiveScreenSnapshot(
            applicationName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Inbox - Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox/abc",
            visibleText: "Reply Send LinkedIn Google Scholar Vinamra Sharma Thanks for reading",
            capturedAt: Date()
        )

        let normalized = DraftActionPlanNormalizer.normalize(
            generated,
            for: "Draft a reply to this email",
            snapshot: snapshot
        )

        XCTAssertEqual(normalized.steps.map(\.kind), [.typeText])
        XCTAssertEqual(normalized.steps[0].text, "Thanks for the update.")
    }

    func testNormalizerTurnsRewriteIntoSafeReplacementInOpenComposer() {
        let generated = DraftActionPlan(
            summary: "Rewrite the draft",
            steps: [
                DraftActionStep(
                    kind: .typeText,
                    title: "Type revised draft",
                    targetHints: ["Message body"],
                    text: "You are doing great work."
                )
            ]
        )
        let snapshot = LiveScreenSnapshot(
            applicationName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Mail - Outlook",
            url: "https://outlook.cloud.microsoft/mail/inbox/id/example",
            visibleText: "Reply Send Discard Bcc Message body Existing draft",
            capturedAt: Date()
        )

        let normalized = DraftActionPlanNormalizer.normalize(
            generated,
            for: "Rewrite this draft and say you are doing great stuff",
            snapshot: snapshot
        )

        XCTAssertEqual(normalized.steps.count, 1)
        XCTAssertEqual(normalized.steps[0].kind, .replaceText)
        XCTAssertEqual(normalized.steps[0].targetHints, ["Message body"])
        XCTAssertNoThrow(try ActionSafetyPolicy.validatePlan(normalized))
    }

    func testRejectsMoreThanOneContentMutation() {
        let plan = DraftActionPlan(
            summary: "Unsafe ambiguous edit",
            steps: [
                DraftActionStep(kind: .typeText, title: "Type", targetHints: ["Message body"], text: "One"),
                DraftActionStep(kind: .replaceText, title: "Replace", targetHints: ["Message body"], text: "Two")
            ]
        )

        XCTAssertThrowsError(try ActionSafetyPolicy.validatePlan(plan))
    }
}

final class ActionTargetingTests: XCTestCase {
    func testGridVisionClickMapsTopLeftCellToWindowTopLeft() {
        let grid = VisionGridSpec(rows: 8, columns: 12)
        let target = GridVisionClickTarget(
            found: true,
            targetLabel: "Reply",
            gridRow: 0,
            gridColumn: 0,
            cellX: 0.5,
            cellY: 0.5,
            confidence: 0.9,
            reasoning: "test"
        )
        let bounds = CGRect(x: 100, y: 200, width: 1200, height: 800)
        let point = target.cocoaPoint(in: bounds, grid: grid)
        XCTAssertNotNil(point)
        // Row 0 is top of image → near window.maxY in Cocoa.
        XCTAssertEqual(point!.x, 100 + (0.5 / 12) * 1200, accuracy: 0.5)
        XCTAssertEqual(point!.y, 200 + 800 - (0.5 / 8) * 800, accuracy: 0.5)
    }

    func testGridVisionClickMapsBottomCellNearWindowBottom() {
        let grid = VisionGridSpec(rows: 8, columns: 12)
        let target = GridVisionClickTarget(
            found: true,
            targetLabel: "Reply",
            gridRow: 7,
            gridColumn: 3,
            cellX: 0.5,
            cellY: 0.5,
            confidence: 0.9,
            reasoning: "test"
        )
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let point = target.cocoaPoint(in: bounds, grid: grid)!
        XCTAssertLessThan(point.y, 150) // near bottom in Cocoa
        XCTAssertGreaterThan(point.x, 250)
        XCTAssertLessThan(point.x, 450)
    }

    func testComposeVisibleWhenSendButtonBoxPresent() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Vision box near bottom of image (low normalized Y).
        let sendBox = ScreenCaptureService.OCRTextBox(
            text: "Send",
            normalizedBounds: CGRect(x: 0.32, y: 0.08, width: 0.08, height: 0.04)
        )
        let capture = WindowCaptureResult(
            image: makeTinyImage(),
            cocoaBounds: bounds
        )
        let snapshot = ActionScreenSnapshot(
            context: ActiveApplicationContext(
                bundleID: "com.google.Chrome",
                applicationName: "Google Chrome",
                windowTitle: "Gmail",
                pid: 1,
                windowID: 1,
                windowBounds: bounds
            ),
            capture: capture,
            visibleText: "Send",
            boxes: [sendBox]
        )
        let finder = ShowMeTargetFinder()
        XCTAssertTrue(finder.composeVisible(in: snapshot))
        XCTAssertNotNil(finder.findSendButtonRect(in: snapshot))
        XCTAssertNotNil(finder.resolveComposeBody(in: snapshot))
        let body = finder.resolveComposeBody(in: snapshot)!
        let sendRect = finder.findSendButtonRect(in: snapshot)!
        // Body click must be above Send (higher Cocoa Y).
        XCTAssertGreaterThan(body.point.y, sendRect.maxY)
    }

    func testReplyBesideForwardPrefersSameRow() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let reply = ScreenCaptureService.OCRTextBox(
            text: "Reply",
            normalizedBounds: CGRect(x: 0.30, y: 0.10, width: 0.07, height: 0.035)
        )
        let forward = ScreenCaptureService.OCRTextBox(
            text: "Forward",
            normalizedBounds: CGRect(x: 0.40, y: 0.10, width: 0.09, height: 0.035)
        )
        let snapshot = ActionScreenSnapshot(
            context: ActiveApplicationContext(
                bundleID: "com.google.Chrome",
                applicationName: "Google Chrome",
                windowTitle: "Gmail",
                pid: 1,
                windowID: 1,
                windowBounds: bounds
            ),
            capture: WindowCaptureResult(image: makeTinyImage(), cocoaBounds: bounds),
            visibleText: "Reply\nForward",
            boxes: [reply, forward]
        )
        let hit = ShowMeTargetFinder().findReplyBesideForward(in: snapshot)
        XCTAssertNotNil(hit)
        XCTAssertLessThan(hit!.point.x, 450)
    }

    func testQuartzCocoaRoundTripOnPrimaryAxis() {
        let cocoa = CGPoint(x: 400, y: 300)
        let quartz = ScreenCoordinates.quartzPoint(fromCocoa: cocoa)
        let back = ScreenCoordinates.cocoaPoint(fromQuartz: quartz)
        XCTAssertEqual(back.x, cocoa.x, accuracy: 0.01)
        XCTAssertEqual(back.y, cocoa.y, accuracy: 0.01)
    }

    private func makeTinyImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
