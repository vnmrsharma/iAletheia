import SwiftUI

struct AgentPersonalityView: View {
    @EnvironmentObject private var preferences: UserPreferencesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThemedInfoBanner(
                    text: "Shape how iAletheia communicates. These preferences apply to every answer.",
                    style: .info
                )

                ThemedSectionCard(title: "Tone", subtitle: "How the agent speaks to you") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Communication style", selection: $preferences.agentPreferences.tone) {
                            ForEach(AgentTone.allCases) { tone in
                                Text(tone.label).tag(tone)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(preferences.agentPreferences.tone.instruction)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.greenLight, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                ThemedSectionCard(title: "Response Style") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Length", selection: $preferences.agentPreferences.responseLength) {
                            ForEach(ResponseLength.allCases) { length in
                                Text(length.label).tag(length)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("Address me by name", isOn: $preferences.agentPreferences.addressUserByName)
                        Toggle("Use emojis", isOn: $preferences.agentPreferences.useEmojis)
                        Toggle("Offer proactive suggestions", isOn: $preferences.agentPreferences.proactiveSuggestions)
                    }
                    .toggleStyle(.switch)
                    .tint(AppTheme.green)
                }

                ThemedSectionCard(title: "Custom Personality", subtitle: "Optional — make it uniquely yours") {
                    ThemedTextField(
                        title: "Personality description",
                        text: $preferences.agentPreferences.personalityDescription,
                        prompt: "e.g. Be like a thoughtful research assistant",
                        axis: .vertical,
                        lineLimit: 3...8
                    )
                }

                ThemedSectionCard(title: "Preview") {
                    Text(preferences.agentPreferences.personalityPrompt(profile: preferences.profile))
                        .font(.callout)
                        .foregroundStyle(AppTheme.textSecondary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(28)
        }
        .background(AppTheme.surface)
        .navigationTitle("Agent Personality")
    }
}
