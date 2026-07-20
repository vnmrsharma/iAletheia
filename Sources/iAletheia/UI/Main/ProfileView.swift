import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var preferences: UserPreferencesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThemedInfoBanner(
                    text: "Help iAletheia understand who you are. This context personalizes answers — stored locally on your Mac.",
                    style: .info
                )

                ThemedSectionCard(title: "Identity", subtitle: "Basic information about you") {
                    VStack(spacing: 16) {
                        ThemedTextField(title: "Your name", text: $preferences.profile.name)
                        ThemedTextField(title: "Role / title", text: $preferences.profile.role, prompt: "e.g. Software Engineer, Researcher")
                        ThemedTextField(title: "Organization", text: $preferences.profile.organization)
                    }
                }

                ThemedSectionCard(title: "About You", subtitle: "Background and interests") {
                    VStack(spacing: 16) {
                        ThemedTextField(title: "Short bio", text: $preferences.profile.bio, axis: .vertical, lineLimit: 3...6)
                        ThemedTextField(title: "Interests", text: $preferences.profile.interests, axis: .vertical, lineLimit: 2...4)
                    }
                }

                ThemedSectionCard(title: "Work Context", subtitle: "What you're focused on right now") {
                    VStack(spacing: 16) {
                        ThemedTextField(title: "Current projects", text: $preferences.profile.currentProjects, axis: .vertical, lineLimit: 2...5)
                        ThemedTextField(title: "Goals", text: $preferences.profile.goals, axis: .vertical, lineLimit: 2...4)
                    }
                }

                ThemedSectionCard(title: "Preview", subtitle: "How the agent sees you") {
                    if preferences.profile.contextBlock().isEmpty {
                        Text("Fill in your profile to see how the agent will understand you.")
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        Text(preferences.profile.contextBlock())
                            .font(.callout)
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.blueLight, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(28)
        }
        .background(AppTheme.surface)
        .navigationTitle("About Me")
    }
}
