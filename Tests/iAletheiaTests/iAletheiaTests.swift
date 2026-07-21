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
