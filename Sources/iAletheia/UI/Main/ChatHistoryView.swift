import SwiftUI

struct ChatHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSessionID: UUID?

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            sessionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.surface)
        .navigationTitle("Chat History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.startNewChatSession()
                    appState.requestedSection = .chat
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
            }
        }
        .onAppear {
            appState.reloadChatSessions()
            if selectedSessionID == nil {
                selectedSessionID = appState.chatSessions.first?.id
            }
        }
    }

    private var sessionList: some View {
        List(selection: $selectedSessionID) {
            if appState.chatSessions.isEmpty {
                Text("No chat sessions yet. Start a conversation in Chat.")
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.callout)
            } else {
                ForEach(appState.chatSessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if session.isActive && session.id == appState.activeChatSessionID {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.green)
                            }
                        }
                        Text(session.preview.isEmpty ? "No messages" : session.preview)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(session.id)
                    .contextMenu {
                        Button("Open in Chat") {
                            appState.openChatSession(id: session.id)
                            appState.requestedSection = .chat
                        }
                        Button("Delete", role: .destructive) {
                            appState.deleteChatSession(id: session.id)
                            if selectedSessionID == session.id {
                                selectedSessionID = appState.chatSessions.first?.id
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let selectedSessionID,
           let session = appState.chatSessions.first(where: { $0.id == selectedSessionID }) {
            let messages = appState.messagesForHistorySession(id: selectedSessionID)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("\(session.messageCount) messages · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Button("Continue in Chat") {
                        appState.openChatSession(id: session.id)
                        appState.requestedSection = .chat
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.blue)
                }
                .padding(20)
                .background(AppTheme.blueLight.opacity(0.35))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            historyBubble(message)
                        }
                    }
                    .padding(20)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a session",
                systemImage: "clock.arrow.circlepath",
                description: Text("Every chat session is saved here so you can revisit past conversations.")
            )
        }
    }

    private func historyBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "iAletheia")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == .user ? .white : AppTheme.textPrimary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.role == .user ? AnyShapeStyle(AppTheme.primaryButtonGradient) : AnyShapeStyle(AppTheme.surfaceMuted))
            )
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
