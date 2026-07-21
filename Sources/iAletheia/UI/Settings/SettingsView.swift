import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKey = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section("Observation") {
                Toggle("Private Mode", isOn: $appState.isPrivateMode)
                Toggle("Cloud answers via OpenAI", isOn: $appState.cloudProcessingEnabled)
                Toggle("Web search for live answers", isOn: $appState.webSearchEnabled)
            }

            Section("OpenAI") {
                SecureField("API Key", text: $apiKey)
                Button("Save API Key") {
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
                Text("GPT-5.6 powers answers and native web search. Stored memories remain local; only redacted context needed for an enabled cloud feature is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let savedMessage {
                    Text(savedMessage).font(.caption)
                }
            }

            Section("Web Search") {
                Text("Uses OpenAI's native web_search tool through the Responses API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Capture, OCR, and memory storage happen locally on your Mac.")
                Text("Screenshots are never persisted.")
                Button("Clear All Local Data", role: .destructive) {
                    appState.clearAllData()
                }
            }

            Section("Permissions") {
                LabeledContent("Screen Recording", value: appState.permissionsGranted.screenRecording ? "Granted" : "Missing")
                LabeledContent("Accessibility", value: appState.permissionsGranted.accessibility ? "Granted" : "Missing")
                Button("Request Permissions") { appState.requestPermissions() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        .padding()
    }
}

struct ObservationTimelineView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(appState.recentObservations) { observation in
            VStack(alignment: .leading, spacing: 4) {
                Text(observation.applicationName).font(.headline)
                if let title = observation.windowTitle {
                    Text(title).font(.caption)
                }
                Text(observation.decision).font(.caption2).foregroundStyle(.secondary)
                Text(observation.capturedAt.formatted()).font(.caption2)
            }
        }
        .navigationTitle("Recent Observations")
    }
}
