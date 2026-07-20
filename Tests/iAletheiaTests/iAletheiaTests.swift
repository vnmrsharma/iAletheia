import Foundation
import XCTest
@testable import iAletheiaCore

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
