import Foundation

/// Expands user queries with related terms so memory retrieval finds relevant screen history.
enum QueryExpander {
    static func expandedSearchTerms(for query: String) -> [String] {
        let lower = query.lowercased()
        var terms = Set<String>()

        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words where word.count > 2 {
            terms.insert(word)
        }

        for marker in ["about ", "for ", "on ", "regarding "] {
            if let range = lower.range(of: marker) {
                let tail = String(lower[range.upperBound...])
                let topic = tail.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init)
                if let topic, topic.count >= 2 {
                    terms.insert(topic)
                }
            }
        }

        if matchesAny(lower, ["search", "searching", "googled", "looked up", "browsing"]) {
            terms.formUnion(["search", "google", "browser", "tab", "history", "results"])
        }
        if matchesAny(lower, ["financial", "finance", "financially", "money", "bank", "account", "invest", "salary", "income", "debt", "credit", "doing well"]) {
            terms.formUnion(["charge", "charges", "fee", "fees", "maintenance", "non-maintenance", "bank", "account", "gmail", "email", "balance", "payment", "a/c"])
        }
        if matchesAny(lower, ["email", "mail", "inbox", "gmail", "message", "notification"]) {
            terms.formUnion(["gmail", "mail", "inbox", "email", "notification", "alert"])
        }
        if matchesAny(lower, ["health", "doctor", "medical", "hospital"]) {
            terms.formUnion(["health", "medical", "doctor", "appointment", "prescription"])
        }
        if matchesAny(lower, ["job", "career", "work", "interview", "offer"]) {
            terms.formUnion(["job", "career", "work", "interview", "offer", "linkedin", "resume"])
        }
        if matchesAny(lower, ["project", "hackathon", "code", "build"]) {
            terms.formUnion(["project", "hackathon", "github", "code", "repository", "readme"])
        }

        return Array(terms)
    }

    static func semanticQueries(for query: String) -> [String] {
        var queries = [query]
        let lower = query.lowercased()

        if matchesAny(lower, ["financial", "finance", "financially", "money", "bank", "account", "doing well"]) {
            queries.append("bank account charges fees maintenance email notification gmail")
        }
        if matchesAny(lower, ["email", "mail", "inbox", "gmail"]) {
            queries.append("gmail email inbox notification message")
        }
        if matchesAny(lower, ["search", "searching", "googled", "looked up", "forgot"]) {
            queries.append(query + " browser tab page")
        }

        return queries
    }

    private static func matchesAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
