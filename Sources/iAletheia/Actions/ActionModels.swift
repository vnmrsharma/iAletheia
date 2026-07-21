import Foundation

enum DraftActionKind: String, Codable {
    case click
    case typeText = "type_text"
    case replaceText = "replace_text"
}

struct DraftActionStep: Codable, Equatable, Identifiable {
    var id = UUID()
    let kind: DraftActionKind
    let title: String
    let targetHints: [String]
    let text: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, text
        case targetHints = "target_hints"
    }

    init(kind: DraftActionKind, title: String, targetHints: [String], text: String?) {
        self.kind = kind
        self.title = title
        self.targetHints = targetHints
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DraftActionKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        targetHints = try container.decode([String].self, forKey: .targetHints)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

struct DraftActionPlan: Codable, Equatable {
    let summary: String
    let steps: [DraftActionStep]
}

/// Converts the model's visual interpretation into a safe UI state transition.
/// A message-reading surface is not editable: Reply must open the composer first.
enum DraftActionPlanNormalizer {
    static func normalize(
        _ plan: DraftActionPlan,
        for query: String,
        snapshot: LiveScreenSnapshot
    ) -> DraftActionPlan {
        guard let contentStep = plan.steps.first(where: { $0.kind == .typeText || $0.kind == .replaceText }) else {
            return plan
        }
        let operation: DraftActionKind = asksToRewrite(query) ? .replaceText : contentStep.kind
        let normalizedContent = DraftActionStep(
            kind: operation,
            title: operation == .replaceText ? "Replace the current draft" : contentStep.title,
            targetHints: contentStep.targetHints,
            text: contentStep.text
        )

        guard shouldOpenReplyEditor(for: query, visibleText: snapshot.visibleText) else {
            // In an already-open composer the model sometimes emits an unnecessary or
            // unverifiable click. Keep only the safe content mutation.
            if operation == contentStep.kind, plan.steps.count == 1 { return plan }
            return DraftActionPlan(summary: plan.summary, steps: [normalizedContent])
        }

        return DraftActionPlan(
            summary: plan.summary,
            steps: [
                DraftActionStep(
                    kind: .click,
                    title: "Open the reply editor",
                    targetHints: ["Reply"],
                    text: nil
                ),
                DraftActionStep(
                    kind: operation,
                    title: normalizedContent.title,
                    targetHints: [],
                    text: normalizedContent.text
                )
            ]
        )
    }

    private static func asksToRewrite(_ query: String) -> Bool {
        let request = query.lowercased()
        return request.contains("make it ")
            || ["rewrite", "replace", "revise", "edit", "change", "shorten", "shorter", "expand",
                "longer", "rephrase", "improve", "polish", "correct", "fix"]
                .contains { containsWord($0, in: request) }
    }

    private static func shouldOpenReplyEditor(for query: String, visibleText: String) -> Bool {
        let request = query.lowercased()
        let screen = visibleText.lowercased()
        let asksForReply = ["reply", "response", "respond"].contains { containsWord($0, in: request) }
        let replyIsVisible = containsWord("reply", in: screen)

        // A composer normally exposes Send together with another compose-only control.
        // Requiring the pair avoids treating the word "send" inside an email as UI state.
        let composeIsOpen = containsWord("send", in: screen)
            && ["discard", "bcc", "format text", "pop out"].contains { screen.contains($0) }
        return asksForReply && replyIsVisible && !composeIsOpen
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ActionSafetyPolicy {
    private static let allowedSignals = [
        "draft", "reply", "response", "respond", "write", "rewrite", "revise", "edit", "change",
        "replace", "rephrase", "shorten", "shorter", "expand", "longer", "improve", "polish", "correct",
        "fix", "make", "add", "tone", "formal", "casual", "friendly", "professional", "grammar", "spelling",
        "compose", "type",
        "email", "message", "linkedin", "slack", "teams", "mail"
    ]

    private static let forbiddenSignals = [
        "send", "submit", "post", "publish", "delete", "remove", "archive",
        "purchase", "buy", "pay", "transfer", "confirm", "accept", "decline",
        "sign", "unsubscribe", "install", "download", "upload"
    ]

    static func validateRequest(_ query: String) throws {
        let normalized = query.lowercased()
        guard allowedSignals.contains(where: normalized.contains) else {
            throw ActionError.unsupportedRequest
        }
        var affirmativeRequest = normalized
        for signal in forbiddenSignals {
            let negated = #"\b(?:do not|don't|dont|never|without)\s+(?:(?:click|press)(?:ing)?\s+)?(?:the\s+)?"#
                + NSRegularExpression.escapedPattern(for: signal)
                + #"\b"#
            affirmativeRequest = affirmativeRequest.replacingOccurrences(
                of: negated,
                with: "",
                options: .regularExpression
            )
        }
        if forbiddenSignals.contains(where: { containsCommand($0, in: affirmativeRequest) }) {
            throw ActionError.forbiddenAction
        }
    }

    static func validatePlan(_ plan: DraftActionPlan) throws {
        guard !plan.steps.isEmpty, plan.steps.count <= 6 else { throw ActionError.invalidPlan }
        let contentSteps = plan.steps.filter({ $0.kind == .typeText || $0.kind == .replaceText })
        guard contentSteps.count == 1,
              plan.steps.filter({ $0.kind == .click }).count <= 2 else { throw ActionError.invalidPlan }
        guard plan.steps.last.map({ $0.kind == .typeText || $0.kind == .replaceText }) == true else {
            throw ActionError.invalidPlan
        }

        for (index, step) in plan.steps.enumerated() {
            let targetText = ([step.title] + step.targetHints).joined(separator: " ").lowercased()
            if forbiddenSignals.contains(where: { containsCommand($0, in: targetText) }) {
                throw ActionError.forbiddenAction
            }
            switch step.kind {
            case .click:
                let genericTargets = Set(["button", "toolbar", "message", "email", "compose", "top", "center"])
                guard !step.targetHints.isEmpty,
                      step.targetHints.allSatisfy({ !genericTargets.contains($0.lowercased()) }),
                      step.targetHints.contains(where: {
                          $0.localizedCaseInsensitiveContains("reply")
                              || $0.localizedCaseInsensitiveContains("respond")
                      }),
                      step.text == nil else { throw ActionError.invalidPlan }
            case .typeText, .replaceText:
                guard let text = step.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      text.count <= 5_000 else { throw ActionError.invalidPlan }
                if step.targetHints.isEmpty {
                    guard plan.steps.count == 1 || (index > 0 && plan.steps[index - 1].kind == .click) else {
                        throw ActionError.invalidPlan
                    }
                } else {
                    let editableSignals = ["message", "reply", "response", "write", "compose", "body", "comment", "chat"]
                    guard step.targetHints.contains(where: { hint in
                        editableSignals.contains(where: { hint.localizedCaseInsensitiveContains($0) })
                    }) else { throw ActionError.invalidPlan }
                }
            }
        }
    }

    private static func containsCommand(_ word: String, in text: String) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ActionError: Error, LocalizedError {
    case unavailable
    case unsupportedRequest
    case forbiddenAction
    case invalidPlan
    case targetWindowUnavailable
    case targetNotFound(String)
    case editableFieldNotFocused
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Action mode requires Accessibility permission, cloud processing enabled, Private Mode off, a readable current screen, and an OpenAI API connection."
        case .unsupportedRequest:
            return "Action mode currently supports drafting text in email and messaging compose fields."
        case .forbiddenAction:
            return "Action mode can prepare a draft, but it cannot send, submit, publish, delete, purchase, or confirm anything."
        case .invalidPlan:
            return "I could not turn that request into a safe draft-only action plan. Nothing was changed or sent."
        case .targetWindowUnavailable:
            return "I stopped because the exact window you were viewing could not be brought back into focus. Nothing was changed or sent."
        case .targetNotFound(let target):
            return "I stopped because I could not verify the on-screen target: \(target). Nothing was sent."
        case .editableFieldNotFocused:
            return "I stopped because I could not verify an editable text field. Nothing was sent."
        case .cancelled:
            return "The action was cancelled. Nothing was sent."
        }
    }
}
