import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKey = ""
    @State private var savedMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThemedSectionCard(title: "Observation") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Private Mode", isOn: $appState.isPrivateMode).tint(AppTheme.green)
                        Toggle("Cloud answers via OpenAI", isOn: $appState.cloudProcessingEnabled).tint(AppTheme.blue)
                        Toggle("Web search for live answers", isOn: $appState.webSearchEnabled).tint(AppTheme.blue)
                        Divider()
                        LabeledContent("Screen Recording") {
                            statusLabel(appState.permissionsGranted.screenRecording)
                        }
                        LabeledContent("Accessibility") {
                            statusLabel(appState.permissionsGranted.accessibility)
                        }
                        SecondaryButton(title: "Request Permissions", icon: "lock.shield") {
                            appState.requestPermissions()
                        }
                    }
                }

                ThemedSectionCard(title: "OpenAI") {
                    VStack(spacing: 14) {
                        ThemedSecureField(title: "API Key", text: $apiKey)
                        PrimaryButton(title: "Save API Key", icon: "key.fill") {
                            Task {
                                do {
                                    let deps = try appState.dependencies
                                    try deps.openAIClient.saveAPIKey(apiKey)
                                    savedMessage = "API key saved to Keychain."
                                } catch {
                                    savedMessage = error.localizedDescription
                                }
                            }
                        }
                        if let savedMessage {
                            ThemedInfoBanner(text: savedMessage, style: .success)
                        }
                    }
                }

                ThemedSectionCard(title: "Web Search", subtitle: "Native OpenAI web search") {
                    ThemedInfoBanner(
                        text: "Uses the Responses API web_search tool when web answers are enabled.",
                        style: .info
                    )
                }

                ThemedSectionCard(title: "Action Mode", subtitle: "Draft-only screen interaction") {
                    ThemedInfoBanner(
                        text: "Action mode can move the cursor, click a verified Reply or compose target, and type a draft. It cannot send, submit, publish, delete, purchase, or confirm actions.",
                        style: .info
                    )
                }

                ThemedSectionCard(title: "Privacy") {
                    VStack(alignment: .leading, spacing: 12) {
                        ThemedInfoBanner(text: "Memories stay on your Mac. Redacted context is sent only for enabled cloud features; screenshots are never saved or uploaded.", style: .success)
                        Button("Clear All Local Data", role: .destructive) {
                            appState.clearAllData()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                ThemedSectionCard(title: "Floating Owl", subtitle: "Drag to any screen edge · Click to chat") {
                    Toggle("Show floating owl widget", isOn: $appState.showOwlWidget)
                        .tint(AppTheme.green)
                        .onChange(of: appState.showOwlWidget) { _, show in
                            if show {
                                OwlWidgetController.shared.show(appState: appState)
                            } else {
                                OwlWidgetController.shared.hide()
                            }
                        }
                }
            }
            .padding(28)
        }
        .background(AppTheme.surface)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func statusLabel(_ granted: Bool) -> some View {
        StatusBadge(text: granted ? "Granted" : "Missing", active: granted)
    }
}
