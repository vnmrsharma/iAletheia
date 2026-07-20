import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isInputFocused: Bool
    @State private var query = ""
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if compact { compactHeader }
            else { chatHeader }
            chatArea
            inputArea
        }
        .background(compact ? AnyView(Color.clear) : AnyView(AppTheme.surface))
        .navigationTitle(compact ? "" : "Chat")
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            AppIconBadge(size: 28, isObserving: appState.isObserving)
            VStack(alignment: .leading, spacing: 1) {
                Text("iAletheia")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(appState.isObserving ? "Learning" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                appState.startNewChatSession()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.body)
                    .foregroundStyle(AppTheme.blue)
            }
            .buttonStyle(.plain)
            .help("New chat")
            Button {
                OwlWidgetController.shared.closeChat()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Close chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.blueLight.opacity(0.35))
    }

    private var chatHeader: some View {
        HStack {
            AppIconBadge(size: 36, isObserving: appState.isObserving)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.activeChatSessionTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(appState.isObserving ? "Session-aware · learning from your screen" : "Observation paused")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                appState.startNewChatSession()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.blue)
            Button {
                appState.openMainApp(section: .history)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.blue)
            Button {
                appState.isObserving ? appState.pauseObservation() : appState.startObservation()
            } label: {
                Label(appState.isObserving ? "Pause" : "Resume", systemImage: appState.isObserving ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.blue)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.blueLight.opacity(0.4))
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(appState.chatMessages) { message in
                        chatBubble(message).id(message.id)
                    }
                    if appState.isQuerying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(AppTheme.blue)
                            Image(systemName: appState.agentActivityPhase.iconName)
                                .font(.caption)
                                .foregroundStyle(AppTheme.blue)
                            Text(appState.queryStatusText)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .padding(.leading, 36)
                    }
                }
                .padding(.horizontal, compact ? 16 : 28)
                .padding(.vertical, 16)
            }
            .onChange(of: appState.chatMessages.count) { _, _ in
                if let last = appState.chatMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 10) {
            if !appState.permissionsGranted.allGranted {
                Button("Grant Screen & Accessibility permissions") {
                    appState.requestPermissions()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.green)
            }

            ThemedChatInput(
                text: $query,
                placeholder: "Ask me anything you've been working on…",
                isLoading: appState.isQuerying,
                onSend: { Task { await submitQuery() } },
                isFocused: $isInputFocused
            )

            HStack(spacing: 14) {
                Label("\(appState.memories.count) memories", systemImage: "tray.full")
                    .foregroundStyle(AppTheme.blue)
                if appState.webSearchEnabled {
                    Label("Web", systemImage: "globe")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                StatusBadge(text: appState.qwenConfigured ? "Qwen connected" : "Local only", active: appState.qwenConfigured)
            }
            .font(.caption2)
        }
        .padding(compact ? 16 : 24)
        .background(AppTheme.surfaceMuted.opacity(0.6))
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 48) }
            if message.role == .assistant {
                AppIconView(size: 26, isObserving: appState.isObserving)
            }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .assistant && !message.citations.isEmpty {
                    InlineCitationText(text: message.text, citations: message.citations)
                } else {
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if message.role == .assistant && !message.citations.isEmpty {
                    CitationFooter(citations: message.citations)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(message.role == .user ? AnyShapeStyle(AppTheme.primaryButtonGradient) : AnyShapeStyle(AppTheme.surfaceMuted))
            )
            .foregroundStyle(message.role == .user ? .white : AppTheme.textPrimary)
            .overlay {
                if message.role == .assistant {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
            }
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private func submitQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = ""
        await appState.askMemory(query: trimmed)
        isInputFocused = true
        if compact { OwlWidgetController.shared.activateForInput() }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case assistant, user }
    let id: UUID
    let role: Role
    let text: String
    let citations: [ChatCitation]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        citations: [ChatCitation] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.timestamp = timestamp
    }
}
