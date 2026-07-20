import AppKit
import SwiftUI

/// Click-through instructor overlay: animated cursor + spotlight. Never clicks for the user.
@MainActor
final class ShowMeOverlayController {
    static let shared = ShowMeOverlayController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<ShowMeOverlayRoot>?

    private init() {}

    func show(step: ShowMeResolvedStep, stepLabel: String) {
        let point = step.targetPoint ?? fallbackPoint()
        let rect = step.targetRect
        ensurePanel(covering: point)
        hosting?.rootView = ShowMeOverlayRoot(
            point: point,
            highlight: rect,
            title: step.title,
            subtitle: stepLabel
        )
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func fallbackPoint() -> CGPoint {
        if let screen = NSScreen.main {
            return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        return CGPoint(x: 400, y: 400)
    }

    private func ensurePanel(covering point: CGPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let panel {
            panel.setFrame(frame, display: true)
            return
        }

        let root = ShowMeOverlayRoot(point: point, highlight: nil, title: "", subtitle: "")
        let host = NSHostingView(rootView: root)
        host.frame = frame

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = host
    }
}

struct ShowMeOverlayRoot: View {
    let point: CGPoint
    let highlight: CGRect?
    let title: String
    let subtitle: String

    var body: some View {
        GeometryReader { geo in
            let local = cocoaToView(point, in: geo.size, viewFrame: geo.frame(in: .global))
            ZStack(alignment: .topLeading) {
                Color.clear

                if let highlight {
                    let r = cocoaRectToView(highlight, in: geo.size)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.85), lineWidth: 3)
                        .background(Color.blue.opacity(0.08))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                }

                ShowMeCursorView()
                    .position(local)

                if !title.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                    )
                    .position(x: min(max(local.x, 120), geo.size.width - 120), y: max(local.y - 56, 40))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Convert Cocoa screen point (bottom-left origin) into SwiftUI view coords for a full-screen panel.
    private func cocoaToView(_ point: CGPoint, in size: CGSize, viewFrame: CGRect) -> CGPoint {
        // Hosting view fills the screen frame; y is flipped vs Cocoa.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let origin = screen?.frame.origin ?? .zero
        let height = screen?.frame.height ?? size.height
        let x = point.x - origin.x
        let y = height - (point.y - origin.y)
        return CGPoint(x: x, y: y)
    }

    private func cocoaRectToView(_ rect: CGRect, in size: CGSize) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) } ?? NSScreen.main
        let origin = screen?.frame.origin ?? .zero
        let height = screen?.frame.height ?? size.height
        let x = rect.origin.x - origin.x
        let y = height - (rect.origin.y - origin.y) - rect.height
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}

struct ShowMeCursorView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.blue.opacity(0.45), lineWidth: 2)
                .frame(width: pulse ? 72 : 48, height: pulse ? 72 : 48)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 28, height: 28)

            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white, Color.blue)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .offset(x: 10, y: 10)
        }
        .onAppear { pulse = true }
    }
}
