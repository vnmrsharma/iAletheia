import Foundation

enum AgentActivityPhase: Equatable, Sendable {
    case thinking
    case readingScreen
    case retrieving
    case searching
    case drafting
    case guiding

    var displayText: String {
        switch self {
        case .thinking: return "Thinking…"
        case .readingScreen: return "Reading screen…"
        case .retrieving: return "Retrieving…"
        case .searching: return "Searching…"
        case .drafting: return "Drafting…"
        case .guiding: return "Planning Show Me…"
        }
    }

    var iconName: String {
        switch self {
        case .thinking: return "brain.head.profile"
        case .readingScreen: return "display"
        case .retrieving: return "tray.full"
        case .searching: return "globe"
        case .drafting: return "text.bubble"
        case .guiding: return "hand.point.up.left"
        }
    }
}

typealias AgentStatusHandler = @Sendable (AgentActivityPhase) -> Void

enum AgentStatusReporter {
    static func mainActor(_ update: @escaping @MainActor (AgentActivityPhase) -> Void) -> AgentStatusHandler {
        { phase in
            Task { @MainActor in
                update(phase)
            }
        }
    }
}
