import AppKit
import SwiftUI

/// Floating panel that accepts keyboard input when chat is open.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum OwlSnapEdge: String, Codable {
    case left, right, top, bottom
}

// MARK: - View model

@MainActor
final class OwlWidgetViewModel: ObservableObject {
    @Published var chatExpanded = false
    @Published var snapEdge: OwlSnapEdge = .right

    weak var controller: OwlWidgetController?

    func closeChat() {
        controller?.setChatExpanded(false, animated: true)
    }

    func activateInput() {
        controller?.activateForInput()
    }
}

// MARK: - Floating Owl + Chat (single panel)

@MainActor
final class OwlWidgetController: NSObject {
    static let shared = OwlWidgetController()

    let viewModel = OwlWidgetViewModel()

    private var panel: KeyablePanel?
    private weak var appState: AppState?

    private var dragStartOrigin: NSPoint = .zero
    private let owlSize: CGFloat = 72
    private let chatWidth: CGFloat = 380
    private let chatHeight: CGFloat = 520
    private let gap: CGFloat = 8
    private let edgeMargin: CGFloat = 14
    private let tapThreshold: CGFloat = 10
    private let positionKey = "ialetheia.owl.position"
    private let snapKey = "ialetheia.owl.snapEdge"

    private var chatVisible: Bool {
        get { viewModel.chatExpanded }
        set { viewModel.chatExpanded = newValue }
    }

    override init() {
        super.init()
        viewModel.controller = self
        if let raw = UserDefaults.standard.string(forKey: snapKey),
           let edge = OwlSnapEdge(rawValue: raw) {
            viewModel.snapEdge = edge
        }
    }

    func show(appState: AppState) {
        self.appState = appState
        if let panel {
            restorePosition(for: panel)
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let root = OwlContainerView(viewModel: viewModel).environmentObject(appState)
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        let size = panelSize(expanded: false)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false

        restorePosition(for: panel)
        self.panel = panel
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
    }

    func hide() {
        setChatExpanded(false, animated: false)
        panel?.orderOut(nil)
        panel = nil
    }

    /// Briefly hide the floating panel so live screen capture can OCR the editor underneath.
    /// Does not change which user window is remembered for capture.
    func withPanelHiddenForCapture<T>(_ work: () async throws -> T) async rethrows -> T {
        let panel = self.panel
        let wasVisible = panel?.isVisible == true
        let wasKey = panel?.isKeyWindow == true
        if wasVisible {
            panel?.orderOut(nil)
            // Let the compositor update before grabbing pixels.
            try? await Task.sleep(for: .milliseconds(80))
        }
        defer {
            if wasVisible {
                panel?.orderFrontRegardless()
                if wasKey {
                    panel?.makeKeyAndOrderFront(nil)
                }
            }
        }
        return try await work()
    }

    func handleClick() {
        guard appState != nil else { return }
        if chatVisible {
            setChatExpanded(false, animated: true)
        } else {
            openChat()
        }
    }

    func openChat() {
        // Lock onto the window the user was viewing BEFORE chat steals focus / Spaces shuffle.
        rememberUserWindowForCapture()
        setChatExpanded(true, animated: true)
    }

    func closeChat() {
        setChatExpanded(false, animated: true)
    }

    func toggleChat(appState: AppState) {
        self.appState = appState
        if chatVisible {
            closeChat()
        } else {
            openChat()
        }
    }

    func setChatExpanded(_ expanded: Bool, animated: Bool) {
        guard chatVisible != expanded else {
            if expanded { activateForInput() }
            return
        }
        if expanded {
            rememberUserWindowForCapture()
        }
        chatVisible = expanded
        resizePanel(expanded: expanded, animated: animated)
        if expanded { activateForInput() }
    }

    func activateForInput() {
        rememberUserWindowForCapture()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rememberUserWindowForCapture() {
        // Prefer AppState's shared service when available.
        if let deps = try? appState?.dependencies {
            deps.activeApplicationService.rememberUserContextBeforeFocusSteal()
        }
    }

    // MARK: - Panel sizing (owl + chat as one unit)

    private func panelSize(expanded: Bool) -> NSSize {
        guard expanded else { return NSSize(width: owlSize, height: owlSize) }
        switch viewModel.snapEdge {
        case .left, .right:
            return NSSize(width: owlSize + gap + chatWidth, height: chatHeight)
        case .top, .bottom:
            return NSSize(width: chatWidth, height: owlSize + gap + chatHeight)
        }
    }

    private func resizePanel(expanded: Bool, animated: Bool) {
        guard let panel else { return }
        let oldFrame = panel.frame
        let newSize = panelSize(expanded: expanded)
        let newOrigin = origin(for: newSize, keeping: viewModel.snapEdge, anchoredTo: oldFrame)

        let apply = {
            panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: newSize)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
            }
        } else {
            apply()
        }
    }

    private func origin(for newSize: NSSize, keeping edge: OwlSnapEdge, anchoredTo oldFrame: NSRect) -> NSPoint {
        switch edge {
        case .right:
            return NSPoint(x: oldFrame.maxX - newSize.width, y: oldFrame.minY)
        case .left:
            return NSPoint(x: oldFrame.minX, y: oldFrame.minY)
        case .bottom:
            return NSPoint(x: oldFrame.minX, y: oldFrame.minY)
        case .top:
            return NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newSize.height)
        }
    }

    // MARK: - Drag & Snap

    func beginDrag() {
        dragStartOrigin = panel?.frame.origin ?? .zero
    }

    func updateDrag(translation: CGSize) {
        guard let panel else { return }
        panel.setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + translation.width,
            y: dragStartOrigin.y - translation.height
        ))
    }

    func finishDrag(translation: CGSize) {
        let distance = hypot(translation.width, translation.height)
        if distance < tapThreshold {
            handleClick()
        } else {
            snapToNearestEdge(animated: true)
        }
    }

    func snapToNearestEdge(animated: Bool) {
        guard let panel, let screen = screenFor(panel: panel) else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame

        let distLeft = frame.midX - visible.minX
        let distRight = visible.maxX - frame.midX
        let distBottom = frame.midY - visible.minY
        let distTop = visible.maxY - frame.midY
        let minDist = min(distLeft, distRight, distBottom, distTop)

        let edge: OwlSnapEdge
        var origin: NSPoint

        if minDist == distLeft {
            edge = .left
            origin = NSPoint(x: visible.minX + edgeMargin, y: clampY(frame.origin.y, frame: frame, visible: visible))
        } else if minDist == distRight {
            edge = .right
            origin = NSPoint(x: visible.maxX - frame.width - edgeMargin, y: clampY(frame.origin.y, frame: frame, visible: visible))
        } else if minDist == distBottom {
            edge = .bottom
            origin = NSPoint(x: clampX(frame.origin.x, frame: frame, visible: visible), y: visible.minY + edgeMargin)
        } else {
            edge = .top
            origin = NSPoint(x: clampX(frame.origin.x, frame: frame, visible: visible), y: visible.maxY - frame.height - edgeMargin)
        }

        viewModel.snapEdge = edge

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }

        savePosition(origin: origin, edge: edge)
    }

    private func clampX(_ x: CGFloat, frame: NSRect, visible: NSRect) -> CGFloat {
        max(visible.minX + edgeMargin, min(x, visible.maxX - frame.width - edgeMargin))
    }

    private func clampY(_ y: CGFloat, frame: NSRect, visible: NSRect) -> CGFloat {
        max(visible.minY + edgeMargin, min(y, visible.maxY - frame.height - edgeMargin))
    }

    private func screenFor(panel: NSPanel) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
    }

    private func savePosition(origin: NSPoint, edge: OwlSnapEdge) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: positionKey)
        UserDefaults.standard.set(edge.rawValue, forKey: snapKey)
    }

    private func restorePosition(for panel: NSPanel) {
        let size = panelSize(expanded: chatVisible)
        var placed = false

        if let dict = UserDefaults.standard.dictionary(forKey: positionKey),
           let x = dict["x"] as? CGFloat,
           let y = dict["y"] as? CGFloat {
            var frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            if let raw = UserDefaults.standard.string(forKey: snapKey),
               let edge = OwlSnapEdge(rawValue: raw) {
                viewModel.snapEdge = edge
                frame.origin = origin(for: size, keeping: edge, anchoredTo: frame)
            }
            if isFrameVisibleOnAnyScreen(frame) {
                panel.setFrame(frame, display: true)
                placed = true
            }
        }

        if !placed, let screen = NSScreen.main ?? NSScreen.screens.first {
            viewModel.snapEdge = .right
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - size.width - edgeMargin,
                y: visible.midY - size.height / 2
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            savePosition(origin: origin, edge: .right)
        }
    }

    private func isFrameVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
        let probe = NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
    }
}

// MARK: - Combined owl + chat layout

struct OwlContainerView: View {
    @ObservedObject var viewModel: OwlWidgetViewModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch viewModel.snapEdge {
            case .left, .right:
                horizontalLayout
            case .top, .bottom:
                verticalLayout
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.chatExpanded)
        .tint(AppTheme.blue)
        .preferredColorScheme(.light)
    }

    private var horizontalLayout: some View {
        HStack(spacing: 8) {
            if viewModel.snapEdge == .left {
                owlSection
                if viewModel.chatExpanded { chatSection }
            } else {
                if viewModel.chatExpanded { chatSection }
                owlSection
            }
        }
    }

    private var verticalLayout: some View {
        VStack(spacing: 8) {
            if viewModel.snapEdge == .top {
                owlSection
                if viewModel.chatExpanded { chatSection }
            } else {
                if viewModel.chatExpanded { chatSection }
                owlSection
            }
        }
    }

    private var chatSection: some View {
        ChatView(compact: true)
            .environmentObject(appState)
            .frame(width: 380, height: 520)
            .background(compactChatBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: snapAnchor)))
    }

    private var compactChatBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppTheme.background)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            }
    }

    private var snapAnchor: UnitPoint {
        switch viewModel.snapEdge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private var owlSection: some View {
        OwlWidgetView()
            .environmentObject(appState)
            .frame(width: 72, height: 72)
    }
}

// MARK: - Owl appearance + native mouse handling

struct OwlWidgetView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppTheme.blueMid.opacity(appState.isObserving ? 0.25 : 0.1),
                            AppTheme.greenMid.opacity(appState.isObserving ? 0.12 : 0.05),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 38
                    )
                )
                .frame(width: 72, height: 72)
                .scaleEffect(pulse && appState.isObserving ? 1.06 : 1.0)
                .animation(appState.isObserving ? .easeInOut(duration: 2.0).repeatForever(autoreverses: true) : .default, value: pulse)

            if let nsImage = AppIcon.image(size: 56) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [AppTheme.blueMid.opacity(0.5), AppTheme.greenMid.opacity(0.5)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    }
                    .shadow(color: AppTheme.blue.opacity(isHovered ? 0.35 : 0.2), radius: isHovered ? 14 : 8)
            }

            if appState.isObserving {
                Circle()
                    .strokeBorder(AppTheme.greenMid.opacity(0.6), lineWidth: 2)
                    .frame(width: 64, height: 64)
            }
        }
        .frame(width: 72, height: 72)
        .overlay { OwlMouseHandler().frame(width: 72, height: 72) }
        .onHover { isHovered = $0 }
        .onAppear { pulse = true }
        .help("Drag to any screen edge · Click to chat")
    }
}

struct OwlMouseHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> OwlMouseNSView { OwlMouseNSView() }
    func updateNSView(_ nsView: OwlMouseNSView, context: Context) {}
}

final class OwlMouseNSView: NSView {
    private var dragStart: NSPoint?
    private var didMove = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        if hypot(dx, dy) > 2 {
            if !didMove {
                OwlWidgetController.shared.beginDrag()
                didMove = true
            }
            OwlWidgetController.shared.updateDrag(translation: CGSize(width: dx, height: -dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        OwlWidgetController.shared.finishDrag(translation: CGSize(width: dx, height: -dy))
        dragStart = nil
        didMove = false
    }
}

typealias FloatingWidgetController = OwlWidgetController
