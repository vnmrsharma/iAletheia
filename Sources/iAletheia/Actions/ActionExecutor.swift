import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Executes draft-only UI actions.
/// Prefer local OCR anchors (Reply↔Forward, Send→body). Vision is a one-shot fallback.
@MainActor
final class ActionExecutor {
    private let targetFinder = ShowMeTargetFinder()
    private let visionGrid = VisionGridSpec.actionGrid
    private let screenCaptureService: ScreenCaptureService
    private let activeApplicationService: ActiveApplicationService
    private let openAIClient: OpenAIClient
    private var cancellationRequested = false

    init(
        screenCaptureService: ScreenCaptureService,
        activeApplicationService: ActiveApplicationService,
        openAIClient: OpenAIClient
    ) {
        self.screenCaptureService = screenCaptureService
        self.activeApplicationService = activeApplicationService
        self.openAIClient = openAIClient
    }

    func cancel() {
        cancellationRequested = true
    }

    func execute(
        plan: DraftActionPlan,
        context: ActiveApplicationContext,
        onProgress: @escaping (String) -> Void
    ) async throws {
        cancellationRequested = false
        defer { ShowMeOverlayController.shared.hide() }
        guard AXIsProcessTrusted() else { throw ActionError.unavailable }
        try ActionSafetyPolicy.validatePlan(plan)

        var workingContext = try await prepareTargetWindow(context, onProgress: onProgress)

        onProgress("Checking the current screen…")
        guard var snapshot = await captureFreshSnapshot(workingContext) else {
            throw ActionError.targetWindowUnavailable
        }
        workingContext = snapshot.context

        guard let contentStep = plan.steps.first(where: { $0.kind == .typeText || $0.kind == .replaceText }),
              let draftText = contentStep.text else {
            throw ActionError.invalidPlan
        }

        let composeOpen = targetFinder.composeVisible(in: snapshot)
        let planWantsReply = plan.steps.contains {
            $0.kind == .click && ShowMeTargetFinder.isReplyClickStep($0.targetHints)
        }

        if planWantsReply && !composeOpen {
            onProgress("Opening reply…")
            let replyStep = plan.steps.first(where: { $0.kind == .click })!
            workingContext = try await openReply(
                context: workingContext,
                snapshot: &snapshot,
                step: replyStep,
                onProgress: onProgress
            )
        } else if composeOpen {
            onProgress("Composer already open — focusing the message body.")
        }

        onProgress("Clicking the message body…")
        try await focusAndType(
            text: draftText,
            replace: contentStep.kind == .replaceText,
            context: workingContext,
            step: contentStep,
            onProgress: onProgress
        )
    }

    // MARK: - Reply

    private func openReply(
        context: ActiveApplicationContext,
        snapshot: inout ActionScreenSnapshot,
        step: DraftActionStep,
        onProgress: @escaping (String) -> Void
    ) async throws -> ActiveApplicationContext {
        try await ensureTargetAppIsFront(context)

        // 1) Prefer Reply sitting beside Forward (reading-pane buttons).
        var localTarget = targetFinder.findReplyBesideForward(in: snapshot)
        if localTarget == nil {
            localTarget = await targetFinder.resolveActionTargetAsync(
                hints: ["Reply"],
                context: snapshot.context,
                captureService: screenCaptureService,
                preferVisualFirst: true
            )
        }
        if let local = localTarget {
            showOverlay(step: step, hit: (local.point, local.rect), label: "Reply")
            try await click(at: local.point)
            try await pause(milliseconds: 600)
            if let after = await captureFreshSnapshot(snapshot.context) {
                snapshot = after
                if targetFinder.composeVisible(in: after) { return after.context }
            }
        }

        // 2) Gmail keyboard shortcut while reading.
        onProgress("Trying Reply shortcut…")
        try await pressKey(code: 15) // R
        try await pause(milliseconds: 550)
        if let after = await captureFreshSnapshot(context) {
            snapshot = after
            if targetFinder.composeVisible(in: after) { return after.context }
        }

        // 3) One vision fallback.
        onProgress("Using vision to find Reply…")
        if let jpeg = gridJPEGBase64(from: snapshot),
           let vision = try? await openAIClient.locateActionClick(
            goal: "Click the labeled Reply button next to Forward at the bottom of the email. Do NOT click Send or the small reply arrow beside Send.",
            appName: snapshot.context.applicationName,
            windowTitle: snapshot.context.windowTitle,
            imageJPEGBase64: jpeg,
            ocrText: snapshot.visibleText,
            grid: visionGrid
           ),
           let point = vision.cocoaPoint(in: snapshot.windowBounds, grid: visionGrid),
           vision.found,
           vision.confidence >= 0.5,
           snapshot.windowBounds.insetBy(dx: 8, dy: 8).contains(point) {
            let rect = CGRect(x: point.x - 48, y: point.y - 18, width: 96, height: 36)
            showOverlay(step: step, hit: (point, rect), label: "Reply")
            try await click(at: point)
            try await pause(milliseconds: 600)
        }

        if let after = await captureFreshSnapshot(context) {
            snapshot = after
            if targetFinder.composeVisible(in: after) { return after.context }
        }
        throw ActionError.targetNotFound("Reply")
    }

    // MARK: - Type

    private func focusAndType(
        text: String,
        replace: Bool,
        context: ActiveApplicationContext,
        step: DraftActionStep,
        onProgress: @escaping (String) -> Void
    ) async throws {
        var working = context

        for attempt in 1...3 {
            try checkCancellation()
            guard let snapshot = await captureFreshSnapshot(working) else {
                throw ActionError.editableFieldNotFocused
            }
            working = snapshot.context

            if !targetFinder.composeVisible(in: snapshot) {
                if attempt == 1 {
                    onProgress("Composer not open — opening Reply first…")
                    var snap = snapshot
                    working = try await openReply(
                        context: working,
                        snapshot: &snap,
                        step: DraftActionStep(kind: .click, title: "Open reply", targetHints: ["Reply"], text: nil),
                        onProgress: onProgress
                    )
                    continue
                }
                throw ActionError.editableFieldNotFocused
            }

            var body = targetFinder.resolveComposeBody(in: snapshot)

            if body == nil, let jpeg = gridJPEGBase64(from: snapshot) {
                onProgress("Using vision to find the text field…")
                if let vision = try? await openAIClient.locateActionClick(
                    goal: "Click inside the empty editable message body ABOVE the blue Send button. Never click Send, Reply arrow, Forward, Recipients, or Subject.",
                    appName: snapshot.context.applicationName,
                    windowTitle: snapshot.context.windowTitle,
                    imageJPEGBase64: jpeg,
                    ocrText: snapshot.visibleText,
                    grid: visionGrid
                ),
                   let point = vision.cocoaPoint(in: snapshot.windowBounds, grid: visionGrid),
                   vision.found,
                   vision.confidence >= 0.5,
                   snapshot.windowBounds.insetBy(dx: 8, dy: 8).contains(point),
                   !isNearSendButton(point, snapshot: snapshot) {
                    body = ShowMeActionTarget(
                        point: point,
                        rect: CGRect(x: point.x - 110, y: point.y - 45, width: 220, height: 90),
                        element: nil
                    )
                }
            }

            guard let target = body else {
                if attempt < 3 { continue }
                throw ActionError.editableFieldNotFocused
            }

            // Never click Send by accident.
            if isNearSendButton(target.point, snapshot: snapshot) {
                if attempt < 3 { continue }
                throw ActionError.editableFieldNotFocused
            }

            showOverlay(step: step, hit: (target.point, target.rect), label: "Message body")
            try await click(at: target.point)
            try await pause(milliseconds: 350)

            // Chrome often won't report AX focus for contenteditable — type anyway once
            // we clicked a verified compose-body target above Send.
            if replace { try await selectAllText() }
            onProgress("Typing your draft…")
            try await typeVisibly(text)
            try await pause(milliseconds: 200)
            return
        }

        throw ActionError.editableFieldNotFocused
    }

    private func isNearSendButton(_ point: CGPoint, snapshot: ActionScreenSnapshot) -> Bool {
        guard let send = targetFinder.findSendButtonRect(in: snapshot) else { return false }
        return send.insetBy(dx: -24, dy: -18).contains(point)
    }

    // MARK: - Window / capture

    private func prepareTargetWindow(
        _ context: ActiveApplicationContext,
        onProgress: @escaping (String) -> Void
    ) async throws -> ActiveApplicationContext {
        onProgress("Bringing your window to the front…")
        OwlWidgetController.shared.closeChat()
        try await pause(milliseconds: 100)

        guard let refreshed = activeApplicationService.activateWindow(for: context) else {
            throw ActionError.targetWindowUnavailable
        }
        try await pause(milliseconds: 180)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == refreshed.pid else {
            throw ActionError.targetWindowUnavailable
        }
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
        return refreshed
    }

    private func ensureTargetAppIsFront(_ context: ActiveApplicationContext) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != context.pid {
            _ = activeApplicationService.activateWindow(for: context)
            try await pause(milliseconds: 120)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else {
            throw ActionError.targetWindowUnavailable
        }
    }

    private func captureFreshSnapshot(_ context: ActiveApplicationContext) async -> ActionScreenSnapshot? {
        let refreshed = activeApplicationService.refreshContextForAction(context)
        _ = activeApplicationService.activateWindow(for: refreshed)
        try? await Task.sleep(for: .milliseconds(100))
        return await targetFinder.captureActionSnapshot(
            context: refreshed,
            captureService: screenCaptureService
        )
    }

    private func gridJPEGBase64(from snapshot: ActionScreenSnapshot) -> String? {
        screenCaptureService.gridAnnotatedJPEGBase64(from: snapshot.capture.image, grid: visionGrid)
    }

    // MARK: - Cursor / keyboard

    private func click(at cocoaPoint: CGPoint) async throws {
        try await moveCursor(toCocoaPoint: cocoaPoint)
        // Land exactly on the target, then click — HID taps often use current cursor position.
        let quartz = ScreenCoordinates.quartzPoint(fromCocoa: cocoaPoint)
        CGWarpMouseCursorPosition(quartz)
        try await pause(milliseconds: 40)
        postClick(atQuartzPoint: quartz)
        try await pause(milliseconds: 40)
    }

    private func showOverlay(step: DraftActionStep, hit: (point: CGPoint, rect: CGRect), label: String) {
        let resolved = ShowMeResolvedStep(
            id: step.id,
            title: step.title,
            instruction: step.title,
            targetHints: step.targetHints,
            targetPoint: hit.point,
            targetRect: hit.rect,
            doneHint: nil
        )
        ShowMeOverlayController.shared.show(step: resolved, stepLabel: label, correctionMode: false)
    }

    private func moveCursor(toCocoaPoint destination: CGPoint) async throws {
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
        let start = NSEvent.mouseLocation
        let steps = 18
        for index in 1...steps {
            try checkCancellation()
            let t = CGFloat(index) / CGFloat(steps)
            let eased = t * t * (3 - 2 * t)
            let cocoa = CGPoint(
                x: start.x + (destination.x - start.x) * eased,
                y: start.y + (destination.y - start.y) * eased
            )
            let quartz = ScreenCoordinates.quartzPoint(fromCocoa: cocoa)
            CGWarpMouseCursorPosition(quartz)
            if let move = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: quartz,
                mouseButton: .left
            ) {
                move.post(tap: .cghidEventTap)
            }
            try await pause(milliseconds: 5)
        }
        // Final snap — avoid leaving the cursor short of the target.
        let finalQuartz = ScreenCoordinates.quartzPoint(fromCocoa: destination)
        CGWarpMouseCursorPosition(finalQuartz)
    }

    private func postClick(atQuartzPoint quartz: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: quartz,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: quartz,
            mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func pressKey(code: CGKeyCode) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func typeVisibly(_ text: String) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            try checkCancellation()
            let utf16 = Array(String(character).utf16)
            guard !utf16.isEmpty else { continue }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up?.post(tap: .cghidEventTap)
            try await pause(milliseconds: character.isWhitespace ? 8 : 12)
        }
    }

    private func selectAllText() async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyA: CGKeyCode = 0
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        try await pause(milliseconds: 100)
    }

    private func pause(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func checkCancellation() throws {
        if cancellationRequested { throw ActionError.cancelled }
        try Task.checkCancellation()
    }
}
