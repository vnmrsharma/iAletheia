import AppKit
import SwiftUI

@MainActor
final class FloatingAssistantPanelController {
    static let shared = FloatingAssistantPanelController()
    private var panel: NSPanel?

    func show(appState: AppState) {
        let content = FloatingAssistantView().environmentObject(appState)
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            panel.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "iAletheia"
            panel.contentView = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.center()
            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct FloatingAssistantView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Memory")
                .font(.title3.bold())

            TextField("What was I researching yesterday about storage?", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await submit() } }

            HStack {
                Button("Search") { Task { await submit() } }
                    .disabled(appState.isQuerying || query.isEmpty)
                if appState.isQuerying {
                    ProgressView().controlSize(.small)
                }
            }

            if let response = appState.assistantResponse {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(response.answer)
                            .textSelection(.enabled)

                        if let notice = response.ambiguityNotice {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Text("Confidence: \(Int(response.confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !response.sources.isEmpty {
                            Divider()
                            Text("Sources")
                                .font(.caption.bold())
                            ForEach(response.sources) { source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).font(.caption.weight(.semibold))
                                    if let url = source.url, let link = URL(string: url) {
                                        Link(url, destination: link).font(.caption2)
                                    }
                                    Text("\(source.applicationName) • \(source.observedAt.formatted())")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Search your local memory",
                    systemImage: "magnifyingglass",
                    description: Text("iAletheia retrieves memories locally and uses Qwen Cloud only to compose answers.")
                )
            }

            Spacer()
        }
        .padding()
    }

    private func submit() async {
        await appState.askMemory(query: query)
    }
}
