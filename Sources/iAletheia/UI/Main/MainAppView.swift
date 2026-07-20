import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Equatable {
    case home
    case memories
    case chat
    case history
    case profile
    case agent
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .memories: return "Memories"
        case .chat: return "Chat"
        case .history: return "Chat History"
        case .profile: return "About Me"
        case .agent: return "Agent"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .memories: return "tray.full.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .history: return "clock.arrow.circlepath"
        case .profile: return "person.crop.circle.fill"
        case .agent: return "sparkles"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainAppView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: UserPreferencesStore
    @State private var selection: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 250)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.surface)
        }
        .background(ThemedBackground())
        .preferredColorScheme(.light)
        .onChange(of: appState.requestedSection) { _, section in
            if let section {
                selection = section
                appState.requestedSection = nil
            }
        }
        .onAppear {
            appState.ensureOwlWidgetShown()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                HStack(spacing: 12) {
                    AppIconBadge(size: 44, isObserving: appState.isObserving)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iAletheia")
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        StatusBadge(
                            text: appState.isObserving ? "Learning" : "Paused",
                            active: appState.isObserving
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Workspace") {
                ForEach([AppSection.home, .memories, .chat, .history]) { section in
                    sidebarRow(section)
                }
            }

            Section("Personalize") {
                ForEach([AppSection.profile, .agent]) { section in
                    sidebarRow(section)
                }
            }

            Section {
                sidebarRow(.settings)
            }

            Section {
                Label("\(appState.memories.count) memories saved", systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.blueLight.opacity(0.5))
        .navigationTitle("iAletheia")
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.icon)
            .tag(section)
            .foregroundStyle(AppTheme.textPrimary)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .home {
        case .home: HomeView()
        case .memories: MemoriesBrowserView()
        case .chat: ChatView(compact: false)
        case .history: ChatHistoryView()
        case .profile: ProfileView()
        case .agent: AgentPersonalityView()
        case .settings: AppSettingsView()
        }
    }
}

struct MemoriesBrowserView: View {
    var body: some View {
        MemoryInspectorView()
    }
}
