import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: UserPreferencesStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statsRow
                quickActions
                recentMemories
            }
            .padding(28)
        }
        .background(AppTheme.surface)
        .navigationTitle("Home")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome back, \(preferences.profile.displayName)")
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.textPrimary)
            Text("Your personal agent is quietly learning from your screen and building a private memory you can search anytime.")
                .font(.body)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            statCard(title: "Memories", value: "\(appState.memories.count)", icon: "tray.full.fill", color: AppTheme.blue)
            statCard(title: "Observations", value: "\(appState.recentObservations.count)", icon: "eye.fill", color: AppTheme.blueMid)
            statCard(
                title: "Status",
                value: appState.isObserving ? "Active" : "Paused",
                icon: appState.isObserving ? "checkmark.circle.fill" : "pause.circle.fill",
                color: appState.isObserving ? AppTheme.green : .orange
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.title3)
                Spacer()
            }
            Text(value)
                .font(.title.bold())
                .foregroundStyle(AppTheme.textPrimary)
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.background)
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.border) }
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        )
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            HStack(spacing: 12) {
                PrimaryButton(title: "Open Chat", icon: "bubble.left.fill") {
                    appState.openChat()
                }
                SecondaryButton(title: appState.isObserving ? "Pause" : "Resume", icon: appState.isObserving ? "pause.fill" : "play.fill") {
                    appState.isObserving ? appState.pauseObservation() : appState.startObservation()
                }
                SecondaryButton(title: "Capture Now", icon: "camera.viewfinder") {
                    Task { await appState.observeCurrentScreen() }
                }
            }
        }
    }

    private var recentMemories: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Memories")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            if appState.memories.isEmpty {
                ContentUnavailableView(
                    "No memories yet",
                    systemImage: "tray",
                    description: Text("Browse, read, and work — iAletheia will learn automatically.")
                )
                .frame(height: 180)
            } else {
                ForEach(appState.memories.prefix(5)) { memory in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [AppTheme.blue, AppTheme.green], startPoint: .top, endPoint: .bottom))
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memory.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(memory.summary)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                Label(memory.sourceApplication, systemImage: "app")
                                Text(memory.lastObservedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.background)
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.border) }
                    )
                }
            }
        }
    }
}
