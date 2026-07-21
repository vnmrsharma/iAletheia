import Foundation

final class PrivacyFilter {
    private let exclusionRepository: ExclusionRepository
    private let sensitiveDetector = SensitivePatternDetector()

    init(exclusionRepository: ExclusionRepository) {
        self.exclusionRepository = exclusionRepository
    }

    func evaluate(
        bundleID: String,
        url: String?,
        text: String,
        windowTitle: String?
    ) -> (decision: PrivacyDecision, sensitivityScore: Double, redactedText: String) {
        if exclusionRepository.isExcluded(bundleID: bundleID, url: url) {
            return (.discard, 1.0, "")
        }
        let lowerTitle = windowTitle?.lowercased() ?? ""
        if lowerTitle.contains("sign in") || lowerTitle.contains("password") || lowerTitle.contains("checkout") {
            return (.discard, 0.9, "")
        }
        let redacted = RedactionService().redact(text)
        let score = sensitiveDetector.score(text: redacted)
        if DisplaySanitizer.containsSensitiveContent(redacted) && score >= AdmissionConfig.sensitivityRejectThreshold {
            return (.discard, score, redacted)
        }
        if score >= AdmissionConfig.sensitivityRejectThreshold {
            return (.discard, score, redacted)
        }
        if score >= 0.5 {
            return (.redactAndRequireApproval, score, redacted)
        }
        return (.allow, score, redacted)
    }
}

enum PrivacyDecision {
    case allow
    case redactAndRequireApproval
    case discard
}

final class SensitivePatternDetector {
    private let patterns: [NSRegularExpression] = {
        let raw = [
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"\b(?:\d[ -]*?){13,16}\b"#,
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?i)\b(?:password|otp|one[- ]time|passcode|api[_ -]?key|secret|bearer)\b"#,
            #"(?i)\b(?:seed phrase|recovery code|private key)\b"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            "OPENAI_API_KEY\\s*=",
            #"sk-[A-Za-z0-9._\-]{8,}"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    func score(text: String) -> Double {
        var hits = 0
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns where pattern.firstMatch(in: text, options: [], range: range) != nil {
            hits += 1
        }
        return min(1.0, Double(hits) * 0.25)
    }
}

final class RedactionService {
    func redact(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"(?i)\b(?:password|otp|passcode|secret|api key)\s*[:=]?\s*\S+"#, "[REDACTED]"),
            (#"OPENAI_API_KEY\s*=\s*\S+"#, "OPENAI_API_KEY=[REDACTED]"),
            (#"sk-[A-Za-z0-9._\-]+"#, "[REDACTED_KEY]"),
            (#"\b(?:\d[ -]*?){13,16}\b"#, "[REDACTED_CARD]"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]")
        ]
        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..<result.endIndex, in: result),
                    withTemplate: replacement
                )
            }
        }
        return result
    }
}

final class PrivateModeController {
    var isEnabled = false
}
