import AppKit
import SwiftUI

/// Click-through instructor overlay: tip of the arrow sits exactly on the target.
@MainActor
final class ShowMeOverlayController {
    static let shared = ShowMeOverlayController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<ShowMeOverlayRoot>?

    private init() {}

    func show(step: ShowMeResolvedStep, stepLabel: String, correctionMode: Bool = false) {
        let point = step.targetPoint ?? fallbackPoint()
        let rect = step.targetRect
        ensurePanel(covering: point)
        let screenFrame = panel?.frame ?? NSScreen.main?.frame ?? .zero
        hosting?.rootView = ShowMeOverlayRoot(
            point: point,
            highlight: rect,
            title: step.title,
            subtitle: stepLabel,
            correctionMode: correctionMode,
            screenFrame: screenFrame
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
            hosting?.frame = NSRect(origin: .zero, size: frame.size)
            return
        }

        let root = ShowMeOverlayRoot(
            point: point,
            highlight: nil,
            title: "",
            subtitle: "",
            correctionMode: false,
            screenFrame: frame
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: frame.size)

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
    var correctionMode: Bool = false
    var screenFrame: CGRect

    private var accent: Color { correctionMode ? Color.orange : Color.blue }

    var body: some View {
        GeometryReader { geo in
            let local = cocoaToView(point)
            ZStack(alignment: .topLeading) {
                Color.clear

                if let highlight {
                    let r = cocoaRectToView(highlight)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accent.opacity(0.95), lineWidth: 3)
                        .background(accent.opacity(0.1))
                        .frame(width: max(r.width, 8), height: max(r.height, 8))
                        .position(x: r.midX, y: r.midY)
                }

                // Tip of the pointer is anchored exactly on `local`.
                ShowMePointerView(accent: accent)
                    .frame(width: 88, height: 88)
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
                            .fill(Color.black.opacity(0.75))
                    )
                    .position(
                        x: min(max(local.x + 70, 130), geo.size.width - 130),
                        y: min(max(local.y - 10, 36), geo.size.height - 36)
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Convert Cocoa screen point → top-left view coords using the overlay panel's screen frame.
    private func cocoaToView(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - screenFrame.minX,
            y: screenFrame.maxY - point.y
        )
    }

    private func cocoaRectToView(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x - screenFrame.minX,
            y: screenFrame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Arrow whose tip sits at the center of this view (the target point).
struct ShowMePointerView: View {
    var accent: Color = .blue
    @State private var pulse = false
    @State private var bob = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.55), lineWidth: 2.5)
                .frame(width: pulse ? 54 : 34, height: pulse ? 54 : 34)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(accent.opacity(0.22))
                .frame(width: 16, height: 16)

            // Tip at the exact target (center). Offset compensates for tip living in the shape's top-left.
            ShowMeArrowShape()
                .fill(Color.white)
                .overlay {
                    ShowMeArrowShape()
                        .stroke(accent, lineWidth: 1.5)
                }
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: 13, y: 13)
                .offset(x: bob ? 1.5 : 0, y: bob ? 1.5 : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bob)
        }
        .onAppear {
            pulse = true
            bob = true
        }
    }
}

/// Triangle tip at (0.15, 0.15) of the unit square — placed so tip ≈ view center when offset.
struct ShowMeArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Tip at top-left-ish of this shape; we position the shape so tip == center of parent ZStack.
        var path = Path()
        let tip = CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.08)
        let baseA = CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.28)
        let baseB = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.72)
        let shaftEnd = CGPoint(x: rect.maxX - 2, y: rect.maxY - 2)

        path.move(to: tip)
        path.addLine(to: baseA)
        path.addLine(to: CGPoint(x: tip.x + rect.width * 0.28, y: tip.y + rect.height * 0.28))
        path.addLine(to: baseB)
        path.closeSubpath()

        // Shaft
        path.move(to: CGPoint(x: tip.x + rect.width * 0.22, y: tip.y + rect.height * 0.22))
        path.addLine(to: shaftEnd)
        path.addLine(to: CGPoint(x: shaftEnd.x - 6, y: shaftEnd.y))
        path.addLine(to: CGPoint(x: tip.x + rect.width * 0.3, y: tip.y + rect.height * 0.34))
        path.closeSubpath()
        return path
    }
}
