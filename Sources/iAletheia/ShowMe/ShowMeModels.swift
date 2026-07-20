import CoreGraphics
import Foundation

struct ShowMePlanStep: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    let title: String
    let instruction: String
    /// Keywords to find on-screen (menu name, button label, etc.).
    let targetHints: [String]
    /// Fallback when AX can't find the control: top | bottom | left | right | center | menubar | ribbon
    let regionHint: String?
    let doneHint: String?

    enum CodingKeys: String, CodingKey {
        case title, instruction, targetHints = "target_hints", regionHint = "region_hint", doneHint = "done_hint"
    }

    init(
        id: UUID = UUID(),
        title: String,
        instruction: String,
        targetHints: [String] = [],
        regionHint: String? = nil,
        doneHint: String? = nil
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.targetHints = targetHints
        self.regionHint = regionHint
        self.doneHint = doneHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decode(String.self, forKey: .instruction)
        targetHints = try c.decodeIfPresent([String].self, forKey: .targetHints) ?? []
        regionHint = try c.decodeIfPresent(String.self, forKey: .regionHint)
        doneHint = try c.decodeIfPresent(String.self, forKey: .doneHint)
    }
}

struct ShowMePlan: Codable, Equatable {
    let intro: String
    let steps: [ShowMePlanStep]
}

struct ShowMeResolvedStep: Identifiable, Equatable {
    let id: UUID
    let title: String
    let instruction: String
    let targetHints: [String]
    /// Cocoa screen coordinates (origin bottom-left of primary display).
    var targetPoint: CGPoint?
    var targetRect: CGRect?
    let doneHint: String?
}

struct ShowMeGuideSession: Identifiable, Equatable {
    let id: UUID
    let query: String
    let intro: String
    var steps: [ShowMeResolvedStep]
    var currentIndex: Int
    var isComplete: Bool

    init(id: UUID = UUID(), query: String, intro: String, steps: [ShowMeResolvedStep], currentIndex: Int = 0) {
        self.id = id
        self.query = query
        self.intro = intro
        self.steps = steps
        self.currentIndex = currentIndex
        self.isComplete = steps.isEmpty
    }

    var currentStep: ShowMeResolvedStep? {
        guard !isComplete, currentIndex >= 0, currentIndex < steps.count else { return nil }
        return steps[currentIndex]
    }

    var progressLabel: String {
        guard !steps.isEmpty else { return "0/0" }
        return "\(min(currentIndex + 1, steps.count))/\(steps.count)"
    }
}
