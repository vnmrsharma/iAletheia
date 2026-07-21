import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Executes draft-only UI actions.
/// Fast path: local OCR/AX first. Vision only as a one-shot fallback when local targeting fails.
@MainActor
final class ActionExecutor {
    private enum VisionPurpose { case reply, messageBody }

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
        defer {
            ShowMeOverlayController.shared.hide()
        }
        guard AXIsProcessTrusted() else { throw ActionError.unavailable }
        try ActionSafetyPolicy.validatePlan(plan)

        var workingContext = try await prepareTargetWindow(context, onProgress: onProgress)

        // One live snapshot decides the real UI state (composer may already be open).
        onProgress("Checking the current screen…")
        guard var snapshot = await captureFreshSnapshot(workingContext) else {
            throw ActionError.targetWindowUnavailable
        }
        workingContext = snapshot.context

        let contentSteps = plan.steps.filter { $0.kind == .typeText || $0.kind == .replaceText }
        guard let contentStep = contentSteps.first, let draftText = contentStep.text else {
            throw ActionError.invalidPlan
        }

        let composeAlreadyOpen = targetFinder.composeVisible(in: snapshot)
        let needsReplyClick = plan.steps.contains {
            $0.kind == .click && ShowMeTargetFinder.isReplyClickStep($0.targetHints)
        } && !composeAlreadyOpen

        if needsReplyClick {
            onProgress("Opening reply…")
            workingContext = try await openReplyFast(
                context: workingContext,
                snapshot: &snapshot,
                step: plan.steps.first(where: { $0.kind == .click })!,
                onProgress: onProgress
            )
        } else if composeAlreadyOpen {
            onProgress("Composer already open — skipping Reply.")
        }

        onProgress("Focusing the message body…")
        try await focusAndType(
            text: draftText,
            replace: contentStep.kind == .replaceText,
            context: workingContext,
            step: contentStep,
            onProgress: onProgress
        )
    }

    // MARK: - Fast Reply open

    private func openReplyFast(
        context: ActiveApplicationContext,
        snapshot: inout ActionScreenSnapshot,
        step: DraftActionStep,
        onProgress: @escaping (String) -> Void
    ) async throws -> ActiveApplicationContext {
        try await ensureTargetAppIsFront(context)

        // 1) Local OCR / Forward-anchor / AX (fast, no API).
        if let local = await targetFinder.resolveActionTargetAsync(
            hints: ["Reply"],
            context: snapshot.context,
            captureService: screenCaptureService,
            preferVisualFirst: true
        ), isSafeTarget(local.point, purpose: .reply, snapshot: snapshot) {
            showOverlay(step: step, hit: (local.point, local.rect), label: "Reply")
            try await click(at: local.point)
            try await pause(milliseconds: 550)
            if let after = await captureFreshSnapshot(snapshot.context) {
                snapshot = after
                if targetFinder.composeVisible(in: after) {
                    return after.context
                }
            }
        }

        // 2) One vision locate only if local missed.
        onProgress("Using vision to find Reply…")
        if let jpeg = gridJPEGBase64(from: snapshot),
           let vision = try? await openAIClient.locateActionClick(
            goal: "Click the Reply button at the bottom of the open email (next to Forward). Do not click Send, Reply all, or the inbox list.",
            appName: snapshot.context.applicationName,
            windowTitle: snapshot.context.windowTitle,
            imageJPEGBase64: jpeg,
            ocrText: snapshot.visibleText,
            grid: visionGrid
           ),
           vision.found,
           vision.confidence >= 0.62,
           let point = vision.cocoaPoint(in: snapshot.windowBounds, grid: visionGrid),
           isSafeTarget(point, purpose: .reply, snapshot: snapshot) {
            let rect = targetRect(around: point, size: CGSize(width: 96, height: 36))
            showOverlay(step: step, hit: (point, rect), label: "Reply")
            try await click(at: point)
            try await pause(milliseconds: 550)
        }

        // 3) Local verify only (no second vision round-trip).
        if let after = await captureFreshSnapshot(context) {
            snapshot = after
            if targetFinder.composeVisible(in: after) {
                return after.context
            }
        }

        throw ActionError.targetNotFound("Reply")
    }

    // MARK: - Focus compose + type

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
                    onProgress("Composer not visible — opening Reply…")
                    var snap = snapshot
                    working = try await openReplyFast(
                        context: working,
                        snapshot: &snap,
                        step: DraftActionStep(kind: .click, title: "Open reply", targetHints: ["Reply"], text: nil),
                        onProgress: onProgress
                    )
                    continue
                }
                throw ActionError.editableFieldNotFocused
            }

            // Prefer local compose-body geometry from the fresh screenshot.
            var target = targetFinder.resolveComposeBody(in: snapshot)

            // One vision call only if local body targeting failed.
            if target == nil, let jpeg = gridJPEGBase64(from: snapshot) {
                onProgress("Using vision to find the text field…")
                if let vision = try? await openAIClient.locateActionClick(
                    goal: "Click inside the editable message body of the open Gmail reply composer (the writing area above the Send button / signature area). Never click Send, Reply arrow, Forward, Recipients, or Subject.",
                    appName: snapshot.context.applicationName,
                    windowTitle: snapshot.context.windowTitle,
                    imageJPEGBase64: jpeg,
                    ocrText: snapshot.visibleText,
                    grid: visionGrid
                ), vision.found, vision.confidence >= 0.62,
                   let point = vision.cocoaPoint(in: snapshot.windowBounds, grid: visionGrid),
                   isSafeTarget(point, purpose: .messageBody, snapshot: snapshot) {
                    target = ShowMeActionTarget(
                        point: point,
                        rect: targetRect(around: point, size: CGSize(width: 220, height: 90)),
                        element: nil
                    )
                }
            }

            guard let body = target,
                  isSafeTarget(body.point, purpose: .messageBody, snapshot: snapshot) else {
                if attempt < 3 { continue }
                throw ActionError.editableFieldNotFocused
            }

            showOverlay(step: step, hit: (body.point, body.rect), label: "Message body")
            try await click(at: body.point)
            try await pause(milliseconds: 280)

            var verifiedEditor = focusedElementIsSafeMessageEditor(pid: working.pid)
            if !verifiedEditor,
               let afterClick = await captureFreshSnapshot(working),
               targetFinder.composeVisible(in: afterClick),
               let jpeg = gridJPEGBase64(from: afterClick),
               let verdict = try? await openAIClient.validateActionScreen(
                intendedStep: "Focused the editable message body; verify it is ready for typing",
                appName: afterClick.context.applicationName,
                windowTitle: afterClick.context.windowTitle,
                imageJPEGBase64: jpeg,
                ocrText: afterClick.visibleText
               ) {
                verifiedEditor = verdict.success
                    && verdict.state == .composeFocused
                    && verdict.nextAction == .type
                    && verdict.confidence >= 0.80
            }
            if verifiedEditor {
                if replace { try await selectAllText() }
                onProgress("Typing your draft…")
                try await typeVisibly(text)
                try await pause(milliseconds: 200)
                return
            }
        }

        throw ActionError.editableFieldNotFocused
    }

    // MARK: - Window / capture

    private func prepareTargetWindow(
        _ context: ActiveApplicationContext,
        onProgress: @escaping (String) -> Void
    ) async throws -> ActiveApplicationContext {
        onProgress("Bringing your window to the front…")
        // Close chat only — keep the owl widget alive so it returns immediately after.
        OwlWidgetController.shared.closeChat()
        try await pause(milliseconds: 120)

        guard let refreshed = activeApplicationService.activateWindow(for: context) else {
            throw ActionError.targetWindowUnavailable
        }
        try await pause(milliseconds: 200)
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
            try await pause(milliseconds: 150)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else {
            throw ActionError.targetWindowUnavailable
        }
    }

    private func captureFreshSnapshot(_ context: ActiveApplicationContext) async -> ActionScreenSnapshot? {
        let refreshed = activeApplicationService.refreshContextForAction(context)
        _ = activeApplicationService.activateWindow(for: refreshed)
        try? await Task.sleep(for: .milliseconds(120))
        return await targetFinder.captureActionSnapshot(
            context: refreshed,
            captureService: screenCaptureService
        )
    }

    private func gridJPEGBase64(from snapshot: ActionScreenSnapshot) -> String? {
        screenCaptureService.gridAnnotatedJPEGBase64(
            from: snapshot.capture.image,
            grid: visionGrid
        )
    }

    private func targetRect(around point: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
               width: size.width, height: size.height)
    }

    /// Rejects dangerous or implausible vision points before moving the cursor.
    private func isSafeTarget(
        _ point: CGPoint,
        purpose: VisionPurpose,
        snapshot: ActionScreenSnapshot
    ) -> Bool {
        let bounds = snapshot.windowBounds.insetBy(dx: 5, dy: 5)
        guard bounds.contains(point) else { return false }

        let forbidden = [
            "send", "submit", "post", "publish", "delete", "discard", "trash",
            "reply all", "forward", "search", "subject", "recipient", "recipients",
            "to", "cc", "bcc"
        ]
        let boxes = snapshot.boxes
        for box in boxes {
            let label = normalizedOCRLabel(box.text)
            guard forbidden.contains(where: { label == $0 || label.hasPrefix($0 + " ") }) else { continue }
            let rect = ScreenCaptureService.screenRect(
                forNormalizedVisionBox: box.normalizedBounds,
                windowCocoaBounds: snapshot.windowBounds
            ).insetBy(dx: -18, dy: -14)
            if rect.contains(point) { return false }
        }

        switch purpose {
        case .reply:
            let replyRects = boxes.compactMap { box -> CGRect? in
                let label = normalizedOCRLabel(box.text)
                guard label == "reply" || label.hasPrefix("reply "),
                      !label.hasPrefix("reply all") else { return nil }
                return ScreenCaptureService.screenRect(
                    forNormalizedVisionBox: box.normalizedBounds,
                    windowCocoaBounds: snapshot.windowBounds
                )
            }
            if !replyRects.isEmpty {
                return replyRects.contains { $0.insetBy(dx: -80, dy: -35).contains(point) }
            }
            return point.x > snapshot.windowBounds.minX + snapshot.windowBounds.width * 0.18
        case .messageBody:
            return targetFinder.composeVisible(in: snapshot)
        }
    }

    private func normalizedOCRLabel(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Input helpers

    private func click(at point: CGPoint) async throws {
        try await moveCursor(toCocoaPoint: point)
        postClick(atCocoaPoint: point)
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
        ShowMeOverlayController.shared.show(
            step: resolved,
            stepLabel: label,
            correctionMode: false
        )
    }

    private func moveCursor(toCocoaPoint destination: CGPoint) async throws {
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
        let start = NSEvent.mouseLocation
        let steps = 16
        for index in 1...steps {
            try checkCancellation()
            let progress = CGFloat(index) / CGFloat(steps)
            let eased = progress * progress * (3 - 2 * progress)
            let cocoaPoint = CGPoint(
                x: start.x + (destination.x - start.x) * eased,
                y: start.y + (destination.y - start.y) * eased
            )
            let quartzPoint = ScreenCoordinates.quartzPoint(fromCocoa: cocoaPoint)
            CGWarpMouseCursorPosition(quartzPoint)
            if let move = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: quartzPoint,
                mouseButton: .left
            ) {
                move.post(tap: .cghidEventTap)
            }
            try await pause(milliseconds: 6)
        }
    }

    private func postClick(atCocoaPoint point: CGPoint) {
        let quartz = ScreenCoordinates.quartzPoint(fromCocoa: point)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartz, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: quartz, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func pressKey(code: CGKeyCode) async throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func typeVisibly(_ text: String) async throws {
        let source = CGEventSource(stateID: .combinedSessionState)
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
            try await pause(milliseconds: character.isWhitespace ? 8 : 14)
        }
    }

    private func selectAllText() async throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyA: CGKeyCode = 0
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        try await pause(milliseconds: 120)
    }

    private func focusedElementIsSafeMessageEditor(pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let element = value as! AXUIElement? else { return false }

        let labels = [
            axString(element, attribute: kAXTitleAttribute),
            axString(element, attribute: kAXDescriptionAttribute),
            axString(element, attribute: kAXRoleDescriptionAttribute),
            axString(element, attribute: kAXIdentifierAttribute),
            axString(element, attribute: "AXPlaceholderValue")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        let forbiddenFields = ["recipient", "subject", "search", "email address", "add people", "carbon copy"]
        guard !forbiddenFields.contains(where: labels.contains),
              !containsShortFieldLabel("to", in: labels),
              !containsShortFieldLabel("cc", in: labels),
              !containsShortFieldLabel("bcc", in: labels) else { return false }

        let frame = axFrame(element)
        let hasEditorGeometry = frame.map { $0.height >= 36 && $0.width >= 140 } ?? false

        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        if role == kAXTextAreaRole as String || role == "AXTextEntryArea" {
            return hasEditorGeometry
        }
        if role == "AXWebArea" || role.contains("Web") {
            return settableStatus == .success && settable.boolValue && hasEditorGeometry
        }
        let editorLabels = ["message", "reply", "response", "write", "compose", "body", "comment", "chat"]
        let hasEditorLabel = editorLabels.contains(where: labels.contains)
        if role == kAXTextFieldRole as String { return hasEditorGeometry && hasEditorLabel }
        return settableStatus == .success && settable.boolValue && hasEditorGeometry && hasEditorLabel
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAX = positionValue as! AXValue?,
              let sizeAX = sizeValue as! AXValue? else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func containsShortFieldLabel(_ label: String, in text: String) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: label) + #"\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func pause(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func checkCancellation() throws {
        if cancellationRequested { throw ActionError.cancelled }
        try Task.checkCancellation()
    }
}
