import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AppIconBadge(size: 36, isObserving: appState.isObserving)
                VStack(alignment: .leading) {
                    Text("iAletheia")
                        .font(.headline)
                    Text(appState.isObserving ? "Observing" : "Paused")
                        .font(.caption)
                        .foregroundStyle(appState.isObserving ? .green : .secondary)
                }
                Spacer()
            }

            if !appState.permissionsGranted.allGranted {
                PermissionBanner()
            }

            HStack {
                Button(appState.isObserving ? "Pause Learning" : "Resume Learning") {
                    appState.isObserving ? appState.pauseObservation() : appState.startObservation()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            if let summary = appState.safeObservationSummary {
                Text(summary)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open App") { appState.openMainApp() }
            Button("Open Chat") { appState.openChat() }
            Button("Memories") { appState.openMainApp(section: .memories) }
            Button("Settings…") { appState.openMainApp(section: .settings) }

            if let error = appState.safeErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            Text("\(appState.memories.count) memories stored locally")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320)
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permissions required", systemImage: "exclamationmark.shield")
                .font(.caption.weight(.semibold))
            HStack {
                Image(systemName: appState.permissionsGranted.screenRecording ? "checkmark.circle.fill" : "xmark.circle")
                Text("Screen Recording")
            }.font(.caption2)
            HStack {
                Image(systemName: appState.permissionsGranted.accessibility ? "checkmark.circle.fill" : "xmark.circle")
                Text("Accessibility")
            }.font(.caption2)
            Button("Grant Permissions") { appState.requestPermissions() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
