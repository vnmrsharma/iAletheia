import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Executes draft-only UI actions. It deliberately exposes no Send/Submit operation.
@MainActor
final class ActionExecutor {
    private let targetFinder = ShowMeTargetFinder()
    private let screenCaptureService: ScreenCaptureService
    private let activeApplicationService: ActiveApplicationService
    private var cancellationRequested = false

    init(
        screenCaptureService: ScreenCaptureService,
        activeApplicationService: ActiveApplicationService
    ) {
        self.screenCaptureService = screenCaptureService
        self.activeApplicationService = activeApplicationService
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

        for (index, step) in plan.steps.enumerated() {
            try checkCancellation()
            workingContext = activeApplicationService.refreshContextForAction(workingContext)
            try await ensureTargetAppIsFront(workingContext)
            onProgress("Action \(index + 1) of \(plan.steps.count): \(step.title)")

            switch step.kind {
            case .click:
                try await performClick(
                    step: step,
                    context: workingContext,
                    index: index,
                    total: plan.steps.count,
                    onProgress: onProgress
                )
            case .typeText, .replaceText:
                try await performTextMutation(step: step, context: workingContext, index: index, total: plan.steps.count)
            }
        }
    }

    private func prepareTargetWindow(
        _ context: ActiveApplicationContext,
        onProgress: @escaping (String) -> Void
    ) async throws -> ActiveApplicationContext {
        onProgress("Bringing your window to the front…")
        OwlWidgetController.shared.closeChat()

        guard let refreshed = activeApplicationService.activateWindow(for: context) else {
            throw ActionError.targetWindowUnavailable
        }
        try await pause(milliseconds: 300)
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
            try await pause(milliseconds: 200)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else {
            throw ActionError.targetWindowUnavailable
        }
    }

    private func performClick(
        step: DraftActionStep,
        context: ActiveApplicationContext,
        index: Int,
        total: Int,
        onProgress: @escaping (String) -> Void
    ) async throws {
        if ShowMeTargetFinder.isReplyClickStep(step.targetHints) {
            onProgress("Opening the reply editor…")
            if try await openReply(context: context, onProgress: onProgress) {
                return
            }
            throw ActionError.targetNotFound(step.targetHints.joined(separator: " / "))
        }

        let preferVisual = ShowMeTargetFinder.isBrowserContext(context)
        guard let target = await resolveTargetWithRetries(
            hints: step.targetHints,
            context: context,
            preferVisualFirst: preferVisual
        ) else {
            throw ActionError.targetNotFound(step.targetHints.joined(separator: " / "))
        }

        showOverlay(step: step, hit: (target.point, target.rect), index: index, total: total)
        try await pause(milliseconds: 120)
        try await moveCursor(toCocoaPoint: target.point)

        if target.hasAccessibilityElement, targetFinder.press(target) {
            // AXPress on the resolved control.
        } else {
            postClick(atCocoaPoint: target.point)
        }
        try await pause(milliseconds: 650)
    }

    /// Opens the reply composer only through a verified live Reply target.
    private func openReply(
        context: ActiveApplicationContext,
        onProgress: @escaping (String) -> Void
    ) async throws -> Bool {
        try await ensureTargetAppIsFront(context)
        onProgress("Locating the visible Reply control…")
        guard let target = await resolveTargetWithRetries(
            hints: ["Reply"],
            context: context,
            preferVisualFirst: true
        ) else { return false }

        try await moveCursor(toCocoaPoint: target.point)
        let usedAccessibilityPress = target.hasAccessibilityElement && targetFinder.press(target)
        if !usedAccessibilityPress {
            postClick(atCocoaPoint: target.point)
        }
        if try await waitForComposer(context: context, attempts: 18) { return true }

        // Some browser nodes report AXPress success without dispatching the webpage's
        // click handler. Retry once at the exact same verified target coordinates.
        if usedAccessibilityPress {
            postClick(atCocoaPoint: target.point)
            if try await waitForComposer(context: context, attempts: 12) { return true }
        }
        return false
    }

    private func waitForComposer(context: ActiveApplicationContext, attempts: Int) async throws -> Bool {
        for _ in 0..<attempts {
            try await pause(milliseconds: 180)
            if await composeIsReady(context: context) { return true }
        }
        return false
    }

    private func composeIsReady(context: ActiveApplicationContext) async -> Bool {
        if focusedElementIsSafeMessageEditor(pid: context.pid) { return true }
        if targetFinder.resolveMessageEditor(context: context) != nil { return true }
        return await targetFinder.composeIsOpen(context: context, captureService: screenCaptureService)
    }

    private func performTextMutation(
        step: DraftActionStep,
        context: ActiveApplicationContext,
        index: Int,
        total: Int
    ) async throws {
        guard let text = step.text else { throw ActionError.invalidPlan }

        if !(await composeIsReady(context: context)) {
            _ = try await openReply(context: context, onProgress: { _ in })
        }

        if !step.targetHints.isEmpty {
            if let hit = await resolveTargetWithRetries(
                hints: step.targetHints,
                context: context,
                preferVisualFirst: ShowMeTargetFinder.isBrowserContext(context)
            ) {
                showOverlay(step: step, hit: (hit.point, hit.rect), index: index, total: total)
                try await pause(milliseconds: 120)
                try await moveCursor(toCocoaPoint: hit.point)
                if !hit.hasAccessibilityElement || !targetFinder.focus(hit) {
                    postClick(atCocoaPoint: hit.point)
                }
                try await pause(milliseconds: 300)
            }
        }

        if !(try await waitForEditableFocus(pid: context.pid, timeoutMilliseconds: 1_500)) {
            if let editor = try await waitForMessageEditor(context: context, timeoutMilliseconds: 4_000) {
                showOverlay(step: step, hit: (editor.point, editor.rect), index: index, total: total)
                try await pause(milliseconds: 120)
                try await moveCursor(toCocoaPoint: editor.point)
                if !editor.hasAccessibilityElement || !targetFinder.focus(editor) {
                    postClick(atCocoaPoint: editor.point)
                }
                try await pause(milliseconds: 250)
            } else if let body = await targetFinder.resolveComposeBodyTarget(
                context: context,
                captureService: screenCaptureService
            ) {
                showOverlay(step: step, hit: (body.point, body.rect), index: index, total: total)
                try await pause(milliseconds: 120)
                try await moveCursor(toCocoaPoint: body.point)
                postClick(atCocoaPoint: body.point)
                try await pause(milliseconds: 300)
            }
        }

        // Compose presence is not enough: typing is permitted only when the verified
        // message-body editor itself owns focus.
        if !focusedElementIsSafeMessageEditor(pid: context.pid) {
            throw ActionError.editableFieldNotFocused
        }
        if step.kind == .replaceText {
            try await selectAllText()
        }
        try await typeVisibly(text)
        try await pause(milliseconds: 250)
    }

    private func resolveTargetWithRetries(
        hints: [String],
        context: ActiveApplicationContext,
        preferVisualFirst: Bool
    ) async -> ShowMeActionTarget? {
        var current = context
        for attempt in 0..<4 {
            if attempt > 0 {
                current = activeApplicationService.refreshContextForAction(current)
                _ = activeApplicationService.activateWindow(for: current)
                try? await pause(milliseconds: 280)
            }
            if let hit = await targetFinder.resolveActionTargetAsync(
                hints: hints,
                context: current,
                captureService: screenCaptureService,
                preferVisualFirst: preferVisualFirst || attempt >= 1
            ) {
                return hit
            }
        }
        return nil
    }

    private func showOverlay(
        step: DraftActionStep,
        hit: (point: CGPoint, rect: CGRect),
        index: Int,
        total: Int
    ) {
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
            stepLabel: "Action \(index + 1)/\(total) · Draft only",
            correctionMode: false
        )
    }

    private func moveCursor(toCocoaPoint destination: CGPoint) async throws {
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
        let start = NSEvent.mouseLocation
        let steps = 32
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
            try await pause(milliseconds: 10)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postClick(atCocoaPoint point: CGPoint) {
        let quartz = ScreenCoordinates.quartzPoint(fromCocoa: point)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartz, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: quartz, mouseButton: .left)?
            .post(tap: .cghidEventTap)
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
            try await pause(milliseconds: character.isWhitespace ? 12 : 20)
        }
    }

    private func selectAllText() async throws {
        try checkCancellation()
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyA: CGKeyCode = 0
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        try await pause(milliseconds: 180)
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
        let hasEditorGeometry = frame.map { $0.height >= 44 && $0.width >= 180 } ?? false

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

    private func waitForEditableFocus(pid: pid_t, timeoutMilliseconds: Int) async throws -> Bool {
        let attempts = max(1, timeoutMilliseconds / 125)
        for _ in 0..<attempts {
            try checkCancellation()
            if focusedElementIsSafeMessageEditor(pid: pid) { return true }
            try await pause(milliseconds: 125)
        }
        return focusedElementIsSafeMessageEditor(pid: pid)
    }

    private func waitForMessageEditor(
        context: ActiveApplicationContext,
        timeoutMilliseconds: Int
    ) async throws -> ShowMeActionTarget? {
        let attempts = max(1, timeoutMilliseconds / 150)
        for _ in 0..<attempts {
            try checkCancellation()
            let refreshed = activeApplicationService.refreshContextForAction(context)
            if let editor = targetFinder.resolveMessageEditor(context: refreshed) { return editor }
            try await pause(milliseconds: 150)
        }
        return targetFinder.resolveMessageEditor(context: activeApplicationService.refreshContextForAction(context))
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
