import Combine
import Foundation

struct UserProfile: Codable, Equatable {
    var name: String = ""
    var role: String = ""
    var organization: String = ""
    var bio: String = ""
    var interests: String = ""
    var currentProjects: String = ""
    var goals: String = ""

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "there" : name
    }

    func contextBlock() -> String {
        var lines: [String] = []
        if !name.isEmpty { lines.append("Name: \(name)") }
        if !role.isEmpty { lines.append("Role: \(role)") }
        if !organization.isEmpty { lines.append("Organization: \(organization)") }
        if !bio.isEmpty { lines.append("About: \(bio)") }
        if !interests.isEmpty { lines.append("Interests: \(interests)") }
        if !currentProjects.isEmpty { lines.append("Current projects: \(currentProjects)") }
        if !goals.isEmpty { lines.append("Goals: \(goals)") }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

enum AgentTone: String, CaseIterable, Codable, Identifiable {
    case polite
    case direct
    case casual
    case professional
    case encouraging

    var id: String { rawValue }

    var label: String {
        switch self {
        case .polite: return "Polite"
        case .direct: return "Direct"
        case .casual: return "Casual"
        case .professional: return "Professional"
        case .encouraging: return "Encouraging"
        }
    }

    var instruction: String {
        switch self {
        case .polite: return "Be warm, respectful, and courteous."
        case .direct: return "Be concise and straight to the point. No fluff."
        case .casual: return "Be relaxed and conversational, like a smart friend."
        case .professional: return "Be polished, structured, and business-appropriate."
        case .encouraging: return "Be supportive, positive, and motivating."
        }
    }
}

enum ResponseLength: String, CaseIterable, Codable, Identifiable {
    case concise
    case balanced
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .concise: return "Concise"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }

    var instruction: String {
        switch self {
        case .concise: return "Keep answers short — 1-3 sentences when possible."
        case .balanced: return "Give enough detail to be useful without being verbose."
        case .detailed: return "Provide thorough, well-structured answers with context."
        }
    }
}

struct AgentPreferences: Codable, Equatable {
    var tone: AgentTone = .polite
    var responseLength: ResponseLength = .balanced
    var personalityDescription: String = ""
    var useEmojis: Bool = false
    var proactiveSuggestions: Bool = true
    var addressUserByName: Bool = true

    func personalityPrompt(profile: UserProfile) -> String {
        var parts = [
            "Communication tone: \(tone.instruction)",
            "Response length: \(responseLength.instruction)"
        ]
        if addressUserByName && !profile.name.isEmpty {
            parts.append("Address the user as \(profile.name).")
        }
        if !personalityDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Custom personality: \(personalityDescription)")
        }
        if useEmojis {
            parts.append("You may use emojis sparingly when appropriate.")
        } else {
            parts.append("Do not use emojis.")
        }
        let userContext = profile.contextBlock()
        if !userContext.isEmpty {
            parts.append("About the user:\n\(userContext)")
        }
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class UserPreferencesStore: ObservableObject {
    @Published var profile: UserProfile {
        didSet { save() }
    }
    @Published var agentPreferences: AgentPreferences {
        didSet { save() }
    }

    private let profileKey = "ialetheia.user.profile"
    private let agentKey = "ialetheia.agent.preferences"

    init() {
        profile = Self.load(key: "ialetheia.user.profile") ?? UserProfile()
        agentPreferences = Self.load(key: "ialetheia.agent.preferences") ?? AgentPreferences()
    }

    func save() {
        Self.persist(profile, key: profileKey)
        Self.persist(agentPreferences, key: agentKey)
    }

    private static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
