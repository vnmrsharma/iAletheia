import Foundation

/// Tracks recent screen content fingerprints to avoid duplicate memories.
final class ContentFingerprintStore {
    private var recent: [String: Date] = [:]
    private let ttl: TimeInterval = 120

    func isDuplicate(fingerprint: String) -> Bool {
        prune()
        return recent[fingerprint] != nil
    }

    func markSeen(_ fingerprint: String) {
        prune()
        recent[fingerprint] = Date()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-ttl)
        recent = recent.filter { $0.value > cutoff }
    }

    static func make(title: String?, url: String?, text: String) -> String {
        let sample = String(text.prefix(800)).lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return "\(title ?? "")|\(url ?? "")|\(sample.hashValue)"
    }
}
