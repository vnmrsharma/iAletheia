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

            if let guide = appState.activeShowMeGuide, let step = guide.currentStep {
                showMeCoachCard(guide: guide, step: step)
            }

            ThemedChatInput(
                text: $query,
                placeholder: appState.showMeEnabled
                    ? "Ask how to do something on screen…"
                    : "Ask me anything you've been working on…",
                isLoading: appState.isQuerying,
                onSend: { Task { await submitQuery() } },
                isFocused: $isInputFocused
            )

            HStack(spacing: 12) {
                Label("\(appState.memories.count) memories", systemImage: "tray.full")
                    .foregroundStyle(AppTheme.blue)

                Button {
                    appState.webSearchEnabled.toggle()
                } label: {
                    Label("Web", systemImage: "globe")
                        .foregroundStyle(appState.webSearchEnabled ? AppTheme.blue : AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Toggle web search")

                Button {
                    appState.showMeEnabled.toggle()
                    if !appState.showMeEnabled {
                        appState.endShowMeGuide(announce: false)
                        ShowMeOverlayController.shared.hide()
                    }
                } label: {
                    Label("Show Me", systemImage: "hand.point.up.left")
                        .foregroundStyle(appState.showMeEnabled ? AppTheme.blue : AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Guide you on screen step by step (does not click for you)")

                Spacer()
                StatusBadge(text: appState.qwenConfigured ? "Qwen connected" : "Local only", active: appState.qwenConfigured)
            }
            .font(.caption2)
        }
        .padding(compact ? 16 : 24)
        .background(AppTheme.surfaceMuted.opacity(0.6))
    }

    private func showMeCoachCard(guide: ShowMeGuideSession, step: ShowMeResolvedStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Show Me · \(guide.progressLabel)", systemImage: "hand.point.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.blue)
                Spacer()
                Button("End") {
                    appState.endShowMeGuide()
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .buttonStyle(.plain)
            }
            Text(step.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(step.instruction)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    appState.advanceShowMeStep()
                } label: {
                    Text(guide.currentIndex + 1 >= guide.steps.count ? "Finish" : "Next step")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.primaryButtonGradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Text("Do this on screen, then tap Next.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.blueLight)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.blue.opacity(0.25), lineWidth: 1)
                }
        )
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
