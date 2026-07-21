import Foundation

enum DisplaySanitizer {
    static func safeSummary(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = redactSecrets(in: value)
        if containsSensitiveContent(value) { return nil }
        return String(value.prefix(180))
    }

    static func safeError(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = redactSecrets(in: value)
        if value.localizedCaseInsensitiveContains("OPENAI_API_KEY") { return "Capture failed. Sensitive content was blocked." }
        return String(value.prefix(160))
    }

    static func containsSensitiveContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "openai_api_key", ".env.local", ".env", "sk-", "api_key=",
            "secret=", "password:", "private key", "recovery code"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func redactSecrets(in text: String) -> String {
        var result = text
        let patterns = [
            #"OPENAI_API_KEY\s*=\s*\S+"#,
            #"sk-[A-Za-z0-9._\-]+"#,
            #"Bearer\s+[A-Za-z0-9._\-]+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..<result.endIndex, in: result),
                    withTemplate: "[REDACTED]"
                )
            }
        }
        return result
    }
}
