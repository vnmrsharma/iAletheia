import AppKit
import SwiftUI

@MainActor
final class MemoryInspectorWindowController: NSWindowController {
    static let shared = MemoryInspectorWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Memory Inspector"
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(appState: AppState) {
        window?.contentView = NSHostingView(rootView: MemoryInspectorView().environmentObject(appState))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MemoryInspectorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var search = ""
    @State private var selectedMemoryID: UUID?

    var filtered: [Memory] {
        guard !search.isEmpty else { return appState.memories }
        return appState.memories.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.summary.localizedCaseInsensitiveContains(search) ||
            ($0.sourceURL?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedMemoryID) {
                ForEach(filtered) { memory in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(memory.summary)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                        Text(memory.lastObservedAt.formatted())
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .tag(memory.id)
                }
            }
            .searchable(text: $search, prompt: "Search memories")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let id = selectedMemoryID, let memory = appState.memories.first(where: { $0.id == id }) {
                MemoryDetailView(memory: memory)
            } else {
                ContentUnavailableView("Select a memory", systemImage: "tray.full")
            }
        }
        .toolbar {
            Button("Delete All", role: .destructive) { appState.clearAllData() }
        }
        .navigationTitle("Memories")
        .background(AppTheme.surface)
    }
}

struct MemoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    let memory: Memory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(memory.title).font(.title2.bold()).foregroundStyle(AppTheme.textPrimary)
                LabeledContent("Type", value: memory.type.rawValue)
                LabeledContent("State", value: memory.memoryState.rawValue)
                LabeledContent("Confidence", value: String(format: "%.0f%%", memory.confidence * 100))
                LabeledContent("Importance", value: String(format: "%.0f%%", memory.importance * 100))
                LabeledContent("First observed", value: memory.firstObservedAt.formatted())
                LabeledContent("Last observed", value: memory.lastObservedAt.formatted())
                if let url = memory.sourceURL, let link = URL(string: url) {
                    Link(url, destination: link)
                }
                if let reason = memory.admissionReason {
                    GroupBox("Why stored") {
                        Text(reason).font(.caption)
                    }
                }
                GroupBox("Summary") {
                    Text(memory.summary).textSelection(.enabled)
                }
                if !memory.topics.isEmpty {
                    GroupBox("Topics") {
                        Text(memory.topics.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                if !memory.keywords.isEmpty {
                    GroupBox("Keywords") {
                        Text(memory.keywords.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                HStack {
                    Button(memory.isPinned ? "Unpin" : "Pin") {
                        appState.pinMemory(id: memory.id, pinned: !memory.isPinned)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.blue)
                    Button("Forget", role: .destructive) {
                        appState.deleteMemory(id: memory.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(AppTheme.surface)
    }
}
