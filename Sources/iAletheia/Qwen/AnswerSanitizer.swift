import Foundation

/// Keeps chat answers clean for plain SwiftUI Text — no markdown chrome.
enum AnswerSanitizer {
    static let plainTextStyle = """
    Formatting rules (strict):
    - Write plain text only. Never use markdown.
    - Do NOT use **bold**, *italic*, `code`, # headings, or markdown links.
    - Do NOT wrap words in asterisks or underscores for emphasis.
    - Prefer short paragraphs and plain numbered lists like "1." "2." when needed.
    """

    static func sanitize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common markdown emphasis / code fences / headings.
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```"#, ""),
            (#"`([^`]+)`"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"(?<!\w)\*([^*]+)\*(?!\w)"#, "$1"),
            (#"(?<!\w)_([^_]+)_(?!\w)"#, "$1"),
            (#"^#{1,6}\s+"#, ""),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)")
        ]

        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..<result.endIndex, in: result),
                    withTemplate: template
                )
            }
        }

        // Catch leftover lone ** or * used as emphasis markers.
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")

        return result
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
