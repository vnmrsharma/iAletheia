import Foundation

/// Continuously learns how the user communicates from chat interactions.
final class ChatLearningService {
    private let memoryRepository: MemoryRepository
    private let profileKey = "ialetheia.communication.profile"

    init(memoryRepository: MemoryRepository) {
        self.memoryRepository = memoryRepository
    }

    var profile: CommunicationProfile {
        get {
            guard let data = UserDefaults.standard.data(forKey: profileKey),
                  let decoded = try? JSONDecoder().decode(CommunicationProfile.self, from: data) else {
                return CommunicationProfile()
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: profileKey)
            }
        }
    }

    func learn(from userQuery: String, route: AnswerRoute) {
        var current = profile
        current.observe(query: userQuery)
        profile = current
        persistPreferenceMemory(from: userQuery, profile: current, route: route)
    }

    func learnedPersonalityAddendum() -> String {
        profile.learnedInstructions()
    }

    private func persistPreferenceMemory(from query: String, profile: CommunicationProfile, route: AnswerRoute) {
        guard profile.queryCount >= 5, profile.queryCount % 5 == 0 else { return }

        let summary = """
        Communication preferences learned from \(profile.queryCount) chat interactions.
        Average query length: \(Int(profile.averageQueryWords)) words.
        Concise preference: \(Int(profile.prefersConcise * 100))%.
        Detail preference: \(Int(profile.prefersDetailed * 100))%.
        Technical language comfort: \(Int(profile.technicalDensity * 100))%.
        Recurring topics: \(profile.recurringTopics.prefix(6).joined(separator: ", ")).
        Recent example: "\(String(query.prefix(120)))"
        """

        let memory = Memory(
            id: preferenceMemoryID(),
            type: .communicationPreference,
            title: "How you communicate with iAletheia",
            content: summary,
            summary: summary,
            topics: ["communication", "preferences"] + profile.recurringTopics.prefix(4),
            keywords: profile.recurringTopics + profile.commonOpeners,
            entities: [],
            sourceApplication: "iAletheia Chat",
            sourceTitle: "Communication profile",
            sourceURL: nil,
            firstObservedAt: profile.lastUpdated,
            lastObservedAt: Date(),
            occurrenceCount: profile.queryCount,
            importance: 0.85,
            confidence: min(0.95, 0.5 + Double(profile.queryCount) * 0.02),
            sensitivity: 0,
            novelty: 0.2,
            attention: 0.7,
            futureUtility: 0.9,
            memoryState: .durable,
            expiresAt: nil,
            isPinned: false,
            isUserCorrected: false,
            embedding: nil,
            relatedMemoryIDs: [],
            evidenceObservationIDs: [],
            cloudProcessed: false,
            admissionReason: "chat_learning:\(route.label)",
            createdAt: profile.lastUpdated,
            updatedAt: Date()
        )

        try? memoryRepository.save(memory)
    }

    private func preferenceMemoryID() -> UUID {
        let key = "ialetheia.communication.memory.id"
        if let existing = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: existing) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
