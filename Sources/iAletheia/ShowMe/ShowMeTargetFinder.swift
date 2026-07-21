import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct ShowMeActivitySnapshot: Equatable {
    var labels: Set<String>
    var selectedLabels: Set<String>
    var focusedLabels: Set<String>
    var windowTitle: String?

    var all: Set<String> {
        labels.union(selectedLabels).union(focusedLabels)
    }
}

enum ShowMeWatchVerdict: Equatable {
    case idle
    case stepCompleted
    case wrongAction(correction: String)
}

struct ShowMeActionTarget {
    let point: CGPoint
    let rect: CGRect
    let element: AXUIElement?

    var hasAccessibilityElement: Bool { element != nil }
}

private enum ShowMeSearchBand {
    case full
    /// Top strip of the window — ribbons, New message, Send, toolbars.
    case toolbar
    /// Reading-pane actions — Reply / Forward under an open email (Gmail, Outlook web).
    case contentActions
}

/// Finds on-screen UI targets via Accessibility + OCR so Show Me can point at real controls.
final class ShowMeTargetFinder {
    /// Resolves an Action-mode target with OCR + AX retries. Prefers visual lock for browsers.
    func resolveActionTargetAsync(
        hints: [String],
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService,
        preferVisualFirst: Bool = false
    ) async -> ShowMeActionTarget? {
        let expanded = expandedActionHints(hints)
        guard !expanded.isEmpty else { return nil }
        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        let primaryBand = searchBand(for: expanded)
        let bands: [ShowMeSearchBand] = {
            if primaryBand == .contentActions { return [.contentActions, .full] }
            if primaryBand == .toolbar { return [.toolbar, .full] }
            return [.full]
        }()

        let attempts: [Bool] = preferVisualFirst ? [true, false] : [false, true]
        for preferVisual in attempts {
            for band in bands {
                if preferVisual,
                   let visual = await findViaOCR(
                    hints: expanded,
                    context: context,
                    captureService: captureService,
                    band: band,
                    actionMode: true
                   ) {
                    return ShowMeActionTarget(point: visual.point, rect: visual.rect, element: nil)
                }

                if let ax = findInAccessibilityTarget(
                    pid: context.pid,
                    hints: expanded,
                    windowBounds: windowBounds,
                    preciseOnly: true,
                    band: band,
                    preferredWindowTitle: context.windowTitle,
                    actionMode: true
                ) {
                    return ax
                }

                if !preferVisual,
                   let visual = await findViaOCR(
                    hints: expanded,
                    context: context,
                    captureService: captureService,
                    band: band,
                    actionMode: true
                   ) {
                    return ShowMeActionTarget(point: visual.point, rect: visual.rect, element: nil)
                }
            }
        }

        if primaryBand != .toolbar,
           let loose = findInAccessibilityTarget(
            pid: context.pid,
            hints: expanded,
            windowBounds: windowBounds,
            preciseOnly: false,
            band: .full,
            preferredWindowTitle: context.windowTitle,
            actionMode: true
           ) {
            return loose
        }
        return nil
    }

    /// Raises the exact remembered app window after the floating widget relinquishes focus.
    /// App activation alone is insufficient when a browser has multiple windows.
    func activateRememberedWindow(context: ActiveApplicationContext) -> Bool {
        let app = AXUIElementCreateApplication(context.pid)
        let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let target = context.windowTitle.flatMap { wanted in
            windows.first(where: { windowMatches($0, title: wanted) })
        } ?? optionalAX(app, kAXFocusedWindowAttribute as String)
        guard let target else { return false }

        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        return raised == .success || windowMatches(target, title: context.windowTitle ?? "")
    }

    /// Full resolve for planning: precise AX → OCR → loose AX → region guess.
    func resolve(
        hints: [String],
        regionHint: String?,
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService? = nil
    ) async -> (point: CGPoint, rect: CGRect)? {
        let normalizedHints = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        let toolbarAction = isToolbarAction(normalizedHints, regionHint: regionHint)
        let primaryBand: ShowMeSearchBand = toolbarAction ? .toolbar : .full

        // 1) Precise AX in the right band (toolbar actions stay in the top strip).
        if !normalizedHints.isEmpty,
           let hit = findInAccessibility(
            pid: context.pid,
            hints: normalizedHints,
            windowBounds: windowBounds,
            preciseOnly: true,
            band: primaryBand
           ) {
            return hit
        }

        // 2) OCR — same band preference.
        if !normalizedHints.isEmpty, let captureService,
           let hit = await findViaOCR(
            hints: normalizedHints,
            context: context,
            captureService: captureService,
            band: primaryBand
           ) {
            return hit
        }

        // 3) Broader AX only for non-toolbar steps (list/sidebar targets).
        if !toolbarAction, !normalizedHints.isEmpty,
           let hit = findInAccessibility(
            pid: context.pid,
            hints: normalizedHints,
            windowBounds: windowBounds,
            preciseOnly: false,
            band: .full
           ) {
            return hit
        }

        // 4) Safe region fallback — never "center" for New message / Send.
        return regionPoint(
            regionHint: regionHint ?? inferredRegion(from: normalizedHints),
            in: windowBounds
        )
    }

    /// AX-only refresh during watching — never falls back to window center.
    func resolveAXRefresh(
        hints: [String],
        context: ActiveApplicationContext
    ) -> (point: CGPoint, rect: CGRect)? {
        let normalizedHints = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedHints.isEmpty else { return nil }
        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        let band: ShowMeSearchBand = isToolbarAction(normalizedHints, regionHint: nil) ? .toolbar : .full
        return findInAccessibility(
            pid: context.pid,
            hints: normalizedHints,
            windowBounds: windowBounds,
            preciseOnly: true,
            band: band
        )
    }

    /// Resolves the live AX element as well as its frame so Action mode can invoke
    /// the exact control rather than relying only on a potentially stale coordinate.
    func resolveActionTarget(hints: [String], context: ActiveApplicationContext) -> ShowMeActionTarget? {
        let expanded = expandedActionHints(hints)
        guard !expanded.isEmpty else { return nil }
        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        let band = searchBand(for: expanded)
        return findInAccessibilityTarget(
            pid: context.pid,
            hints: expanded,
            windowBounds: windowBounds,
            preciseOnly: true,
            band: band,
            preferredWindowTitle: context.windowTitle,
            actionMode: true
        )
    }

    func press(_ target: ShowMeActionTarget) -> Bool {
        guard let element = target.element else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    func focus(_ target: ShowMeActionTarget) -> Bool {
        guard let element = target.element else { return false }
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Finds a newly-created writable message body after Reply opens a web composer.
    /// Recipient, subject, search, and other compact text fields are excluded.
    func resolveMessageEditor(context: ActiveApplicationContext) -> ShowMeActionTarget? {
        let app = AXUIElementCreateApplication(context.pid)
        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let preferred = context.windowTitle.flatMap { wanted in
            windows.first(where: { windowMatches($0, title: wanted) })
        }
        guard let root = preferred ?? optionalAX(app, kAXFocusedWindowAttribute as String) else { return nil }
        var best: (score: Int, area: CGFloat, rect: CGRect, element: AXUIElement)?
        searchMessageEditor(element: root, depth: 0, windowBounds: windowBounds, best: &best)
        guard let best else { return nil }
        return ShowMeActionTarget(point: pointInRect(best.rect), rect: best.rect, element: best.element)
    }

    /// Exact visual fallback for browser controls omitted from the AX tree. This never
    /// returns a guessed region: a matching OCR box must exist inside the locked window.
    func resolveExactOCRTarget(
        hints: [String],
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService
    ) async -> (point: CGPoint, rect: CGRect)? {
        let normalizedHints = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedHints.isEmpty else { return nil }
        let band = searchBand(for: normalizedHints)
        return await findViaOCR(
            hints: normalizedHints,
            context: context,
            captureService: captureService,
            band: band,
            actionMode: true
        )
    }

    func activitySnapshot(pid: pid_t) -> ShowMeActivitySnapshot {
        let app = AXUIElementCreateApplication(pid)
        var selected = Set<String>()
        var focused = Set<String>()
        var labels = Set<String>()

        if let focus = optionalAX(app, kAXFocusedUIElementAttribute as String) {
            for label in elementLabels(focus, includeValue: false) {
                focused.insert(normalizeLabel(label))
                labels.insert(normalizeLabel(label))
            }
            collectSelected(from: focus, into: &selected)
        }

        if let window = optionalAX(app, kAXFocusedWindowAttribute as String) {
            collectSelected(from: window, into: &selected)
            harvestSelectedDeep(window, depth: 0, into: &selected)
        }

        for s in selected { labels.insert(s) }
        for f in focused { labels.insert(f) }

        var title: String?
        if let window = optionalAX(app, kAXFocusedWindowAttribute as String) {
            title = elementLabels(window, includeValue: false).first
        }

        return ShowMeActivitySnapshot(
            labels: labels.filter { !$0.isEmpty },
            selectedLabels: selected.filter { !$0.isEmpty },
            focusedLabels: focused.filter { !$0.isEmpty },
            windowTitle: title
        )
    }

    func evaluateProgress(
        current: ShowMeResolvedStep,
        allSteps: [ShowMeResolvedStep],
        currentIndex: Int,
        baseline: ShowMeActivitySnapshot,
        latest: ShowMeActivitySnapshot
    ) -> ShowMeWatchVerdict {
        let newLabels = latest.all.subtracting(baseline.all)
        let meaningfulNew = newLabels.filter { $0.count >= 2 }
        let currentHints = matchKeys(for: current)

        if !meaningfulNew.isEmpty {
            if meaningfulNew.contains(where: { matches($0, hints: currentHints) }) {
                return .stepCompleted
            }

            for (idx, step) in allSteps.enumerated() where idx > currentIndex {
                let hints = matchKeys(for: step)
                if meaningfulNew.contains(where: { matches($0, hints: hints) }) {
                    if isLooseStep(current) {
                        return .stepCompleted
                    }
                }
            }

            if let wrong = meaningfulNew.first(where: { label in
                !matches(label, hints: currentHints)
                    && !allSteps.dropFirst(currentIndex).contains { matches(label, hints: matchKeys(for: $0)) }
                    && looksLikeUserChoice(label)
            }) {
                let expected = currentHints.prefix(3).joined(separator: " / ")
                let correction = expected.isEmpty
                    ? "That doesn't look like this step. Try again: \(current.instruction)"
                    : "Looks like you selected \"\(wrong)\" — for this step look for \(expected) instead."
                return .wrongAction(correction: correction)
            }
        }

        let newlySelected = latest.selectedLabels.subtracting(baseline.selectedLabels)
        if newlySelected.contains(where: { matches($0, hints: currentHints) }) {
            return .stepCompleted
        }

        let newlyFocused = latest.focusedLabels.subtracting(baseline.focusedLabels)
        if newlyFocused.contains(where: { matches($0, hints: currentHints) }) {
            return .stepCompleted
        }

        return .idle
    }

    // MARK: - OCR

    private func findViaOCR(
        hints: [String],
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService,
        band: ShowMeSearchBand,
        actionMode: Bool = false
    ) async -> (point: CGPoint, rect: CGRect)? {
        await OwlWidgetController.shared.withPanelHiddenForCapture {
            guard let capture = try? await captureService.captureActiveWindow(
                for: context.pid,
                windowID: context.windowID,
                windowBounds: context.windowBounds
            ) else { return nil }

            guard let boxes = try? await captureService.ocrTextBoxes(from: capture.image), !boxes.isEmpty else {
                return nil
            }

            let windowBounds = capture.cocoaBounds
            // Keep original word boxes. Merging can turn two neighbouring buttons into
            // one label ("Reply Forward") and destroy the exact actionable target.
            let candidates = boxes + mergeAdjacentOCRBoxes(boxes)
            let minScore = actionMode ? 8 : 12
            var best: (score: Int, area: CGFloat, rect: CGRect)?

            for box in candidates {
                let raw = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = normalizeLabel(raw)
                guard !label.isEmpty, !looksLikeInboxNoise(raw) else { continue }

                let score = actionMode
                    ? actionHintMatchScore(label: label, hints: hints)
                    : hintMatchScore(label: label, hints: hints)
                guard score >= minScore else { continue }

                let screen = ScreenCaptureService.screenRect(
                    forNormalizedVisionBox: box.normalizedBounds,
                    windowCocoaBounds: windowBounds
                )
                guard acceptsFrame(
                    screen,
                    windowBounds: windowBounds,
                    band: band,
                    toolbarBias: isToolbarAction(hints, regionHint: nil),
                    actionMode: actionMode
                ) else {
                    continue
                }

                if actionMode && isContentAction(hints, regionHint: nil),
                   !looksLikeReplyLabel(label) {
                    continue
                }

                let area = screen.width * screen.height
                if area > windowBounds.width * windowBounds.height * 0.08 { continue }
                if screen.height > 88 { continue }

                var ranked = score
                ranked += toolbarPositionBonus(frame: screen, windowBounds: windowBounds, hints: hints)
                ranked += contentActionPositionBonus(frame: screen, windowBounds: windowBounds, hints: hints)
                ranked += replyButtonPositionBonus(frame: screen, windowBounds: windowBounds, hints: hints)

                if best == nil || ranked > best!.score || (ranked == best!.score && area < best!.area) {
                    best = (ranked, area, screen)
                }
            }

            guard let best else { return nil }
            return (pointInRect(best.rect), best.rect)
        }
    }

    /// Clicks the inline compose body using a fresh post-Reply screenshot.
    func resolveComposeBodyTarget(
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService
    ) async -> ShowMeActionTarget? {
        guard let snapshot = await captureActionSnapshot(context: context, captureService: captureService) else {
            return nil
        }
        return resolveComposeBody(in: snapshot)
    }

    func captureActionSnapshot(
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService
    ) async -> ActionScreenSnapshot? {
        await OwlWidgetController.shared.withPanelHiddenForCapture {
            guard let capture = try? await captureService.captureActiveWindow(
                for: context.pid,
                windowID: context.windowID,
                windowBounds: context.windowBounds
            ) else { return nil }
            // Single OCR pass — boxes are enough for text + geometry.
            let boxes = (try? await captureService.ocrTextBoxes(from: capture.image)) ?? []
            let visibleText = boxes.map(\.text).joined(separator: "\n")
            return ActionScreenSnapshot(
                context: context,
                capture: capture,
                visibleText: visibleText,
                boxes: boxes
            )
        }
    }

    func composeVisible(in snapshot: ActionScreenSnapshot) -> Bool {
        // A browser's page-level AXWebArea can appear writable even in read-only email
        // view. Only trust AX editor discovery in native apps; webmail must show compose UI.
        if !Self.isBrowserContext(snapshot.context),
           resolveMessageEditor(context: snapshot.context) != nil { return true }
        let text = snapshot.visibleText.lowercased()
        let hasSend = containsWord("send", in: text)
        let fullCompose = ["recipients", "discard", "bcc", "subject"].contains { text.contains($0) }
        // Gmail inline bottom reply: Send button in the lower strip, often with signature links.
        let inlineCompose = boxesContainSendButton(in: snapshot)
        return hasSend && (fullCompose || inlineCompose)
    }

    private func boxesContainSendButton(in snapshot: ActionScreenSnapshot) -> Bool {
        let bounds = snapshot.windowBounds
        for box in snapshot.boxes + mergeAdjacentOCRBoxes(snapshot.boxes) {
            let label = normalizeLabel(box.text)
            guard label == "send" || label.hasPrefix("send ") else { continue }
            let rect = ScreenCaptureService.screenRect(
                forNormalizedVisionBox: box.normalizedBounds,
                windowCocoaBounds: bounds
            )
            if rect.midY <= bounds.minY + bounds.height * 0.45,
               rect.height <= 64,
               rect.width <= 160 {
                return true
            }
        }
        return false
    }

    /// Locates the message body from the current screenshot (after Reply reshapes the page).
    func resolveComposeBody(in snapshot: ActionScreenSnapshot) -> ShowMeActionTarget? {
        // Browser AX frequently exposes a large writable AXWebArea for the entire page.
        // It is not the compose body, even though AXValue happens to be settable.
        if !Self.isBrowserContext(snapshot.context),
           let ax = resolveMessageEditor(context: snapshot.context) {
            return ax
        }

        let bounds = snapshot.windowBounds
        let merged = snapshot.boxes + mergeAdjacentOCRBoxes(snapshot.boxes)
        var recipientsRect: CGRect?
        var sendRect: CGRect?
        var discardRect: CGRect?

        for box in merged {
            let label = normalizeLabel(box.text)
            let rect = ScreenCaptureService.screenRect(
                forNormalizedVisionBox: box.normalizedBounds,
                windowCocoaBounds: bounds
            )
            guard rect.midX > bounds.minX + bounds.width * 0.22 else { continue }

            if label.contains("recipient") || label == "to" {
                if recipientsRect == nil || rect.maxY > recipientsRect!.maxY {
                    recipientsRect = rect
                }
            }
            if label == "send" || label.hasPrefix("send ") {
                if sendRect == nil || rect.midY < sendRect!.midY {
                    sendRect = rect
                }
            }
            if label.contains("discard") {
                discardRect = rect
            }
        }

        if let recipientsRect, let sendRect, recipientsRect.minY > sendRect.maxY + 24 {
            let insetX = max(recipientsRect.minX, bounds.minX + bounds.width * 0.28)
            let bodyMinY = sendRect.maxY + 14
            let bodyMaxY = recipientsRect.minY - 10
            let height = bodyMaxY - bodyMinY
            guard height >= 36 else { return nil }
            let bodyRect = CGRect(
                x: insetX,
                y: bodyMinY,
                width: min(bounds.width * 0.56, max(recipientsRect.width * 2.8, 320)),
                height: height
            )
            return ShowMeActionTarget(point: pointInRect(bodyRect), rect: bodyRect, element: nil)
        }

        if let sendRect {
            // Gmail bottom reply: writing area is ABOVE the Send/toolbar row, across the reading pane.
            let bodyHeight = max(72, min(140, bounds.height * 0.13))
            let bodyRect = CGRect(
                x: bounds.minX + bounds.width * 0.34,
                y: sendRect.maxY + 20,
                width: bounds.width * 0.50,
                height: bodyHeight
            )
            let clamped = bodyRect.intersection(bounds.insetBy(dx: 8, dy: 8))
            if clamped.width >= 120, clamped.height >= 40 {
                return ShowMeActionTarget(point: pointInRect(clamped), rect: clamped, element: nil)
            }
        }

        if let recipientsRect {
            let bodyHeight = max(80, bounds.height * 0.15)
            let bodyRect = CGRect(
                x: recipientsRect.minX,
                y: recipientsRect.minY - bodyHeight - 12,
                width: min(bounds.width * 0.54, 520),
                height: bodyHeight
            )
            return ShowMeActionTarget(point: pointInRect(bodyRect), rect: bodyRect, element: nil)
        }

        if let discardRect {
            let bodyRect = CGRect(
                x: discardRect.minX,
                y: discardRect.maxY + 20,
                width: min(bounds.width * 0.52, 480),
                height: max(72, bounds.height * 0.14)
            )
            return ShowMeActionTarget(point: pointInRect(bodyRect), rect: bodyRect, element: nil)
        }

        return nil
    }

    func composeIsOpen(
        context: ActiveApplicationContext,
        captureService: ScreenCaptureService
    ) async -> Bool {
        if resolveMessageEditor(context: context) != nil { return true }
        return await OwlWidgetController.shared.withPanelHiddenForCapture {
            guard let capture = try? await captureService.captureActiveWindow(
                for: context.pid,
                windowID: context.windowID,
                windowBounds: context.windowBounds
            ) else { return false }
            let text = ((try? await captureService.ocrText(from: capture.image)) ?? "").lowercased()
            let hasSend = containsWord("send", in: text)
            let hasComposeChrome = ["recipients", "discard", "bcc", "subject"].contains { text.contains($0) }
            return hasSend && hasComposeChrome
        }
    }

    private func isInBottomActionStrip(frame: CGRect, windowBounds: CGRect) -> Bool {
        frame.midY <= windowBounds.minY + windowBounds.height * 0.42
    }

    private func looksLikeReplyLabel(_ label: String) -> Bool {
        let canonical = label.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return canonical == "reply" || canonical == "respond"
            || (canonical.hasPrefix("reply ") && !canonical.hasPrefix("reply all") && canonical.count <= 20)
    }

    private func replyButtonPositionBonus(frame: CGRect, windowBounds: CGRect, hints: [String]) -> Int {
        guard isContentAction(hints, regionHint: nil) else { return 0 }
        if isInBottomActionStrip(frame: frame, windowBounds: windowBounds) { return 12 }
        return -40
    }

    private func mergeAdjacentOCRBoxes(_ boxes: [ScreenCaptureService.OCRTextBox]) -> [ScreenCaptureService.OCRTextBox] {
        guard boxes.count > 1 else { return boxes }
        var merged: [ScreenCaptureService.OCRTextBox] = []
        let sorted = boxes.sorted {
            if abs($0.normalizedBounds.midY - $1.normalizedBounds.midY) > 0.012 {
                return $0.normalizedBounds.midY > $1.normalizedBounds.midY
            }
            return $0.normalizedBounds.minX < $1.normalizedBounds.minX
        }

        var index = 0
        while index < sorted.count {
            var current = sorted[index]
            var nextIndex = index + 1
            while nextIndex < sorted.count {
                let candidate = sorted[nextIndex]
                let sameLine = abs(candidate.normalizedBounds.midY - current.normalizedBounds.midY) <= 0.014
                let adjacent = candidate.normalizedBounds.minX - current.normalizedBounds.maxX <= 0.04
                if sameLine && adjacent {
                    let union = current.normalizedBounds.union(candidate.normalizedBounds)
                    current = ScreenCaptureService.OCRTextBox(
                        text: "\(current.text) \(candidate.text)",
                        normalizedBounds: union
                    )
                    nextIndex += 1
                } else {
                    break
                }
            }
            merged.append(current)
            index = nextIndex
        }
        return merged
    }

    // MARK: - AX search

    private func findInAccessibility(
        pid: pid_t,
        hints: [String],
        windowBounds: CGRect,
        preciseOnly: Bool,
        band: ShowMeSearchBand
    ) -> (point: CGPoint, rect: CGRect)? {
        guard let target = findInAccessibilityTarget(
            pid: pid,
            hints: hints,
            windowBounds: windowBounds,
            preciseOnly: preciseOnly,
            band: band
        ) else { return nil }
        return (target.point, target.rect)
    }

    private func findInAccessibilityTarget(
        pid: pid_t,
        hints: [String],
        windowBounds: CGRect,
        preciseOnly: Bool,
        band: ShowMeSearchBand,
        preferredWindowTitle: String? = nil,
        actionMode: Bool = false
    ) -> ShowMeActionTarget? {
        let app = AXUIElementCreateApplication(pid)
        var best: (score: Int, area: CGFloat, rect: CGRect, element: AXUIElement)?
        let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let preferredWindow = preferredWindowTitle.flatMap { wanted in
            windows.first(where: { windowMatches($0, title: wanted) })
        }

        if let root = preferredWindow ?? optionalAX(app, kAXFocusedWindowAttribute as String) {
            search(
                element: root,
                hints: hints,
                depth: 0,
                windowBounds: windowBounds,
                preciseOnly: preciseOnly,
                band: band,
                actionMode: actionMode,
                best: &best
            )
        }

        if best == nil {
            for window in windows.prefix(4) {
                search(
                    element: window,
                    hints: hints,
                    depth: 0,
                    windowBounds: windowBounds,
                    preciseOnly: preciseOnly,
                    band: band,
                    actionMode: actionMode,
                    best: &best
                )
                if best != nil { break }
            }
        }

        guard let best, best.score >= 12 else { return nil }
        return ShowMeActionTarget(point: pointInRect(best.rect), rect: best.rect, element: best.element)
    }

    private func windowMatches(_ window: AXUIElement, title wanted: String) -> Bool {
        let wanted = normalizeLabel(wanted)
        guard wanted.count >= 3 else { return false }
        return elementLabels(window, includeValue: false).contains { candidate in
            let candidate = normalizeLabel(candidate)
            return candidate == wanted || candidate.contains(wanted) || wanted.contains(candidate)
        }
    }

    private func search(
        element: AXUIElement,
        hints: [String],
        depth: Int,
        windowBounds: CGRect,
        preciseOnly: Bool,
        band: ShowMeSearchBand,
        actionMode: Bool = false,
        best: inout (score: Int, area: CGFloat, rect: CGRect, element: AXUIElement)?
    ) {
        guard depth < 22 else { return }

        let role = normalizeLabel(elementRole(element) ?? "")
        let preferValue = role.contains("axtextfield") || role.contains("axtextarea")
        let labels = elementLabels(element, includeValue: preferValue).map(normalizeLabel)

        var score = 0
        for label in labels {
            score = max(
                score,
                actionMode ? actionHintMatchScore(label: label, hints: hints) : hintMatchScore(label: label, hints: hints)
            )
        }

        if score > 0, let frame = elementFrame(element, in: windowBounds) {
            let area = frame.width * frame.height
            let windowArea = max(1, windowBounds.width * windowBounds.height)
            let isButtonLike = ["axbutton", "axmenuitem", "axlink", "axpopupbutton", "axcheckbox", "axradiobutton"]
                .contains(where: { role.contains($0) })
            let isHuge = area > windowArea * 0.12
                || frame.width > windowBounds.width * 0.5
                || frame.height > windowBounds.height * 0.25

            if !acceptsFrame(
                frame,
                windowBounds: windowBounds,
                band: band,
                toolbarBias: isToolbarAction(hints, regionHint: nil)
            ) {
                score = 0
            }

            if preciseOnly {
                if isHuge && !isButtonLike { score = 0 }
                if role.contains("axwebarea") || role.contains("axscrollarea") { score = 0 }
                if role.contains("axgroup") && isHuge { score = 0 }
                let smallExactControl = frame.height <= 52 && frame.width <= 220
                if role.contains("axstatictext") || role.contains("axcell") || role.contains("axrow") {
                    if actionMode && smallExactControl && score >= 18 {
                        score += 4
                    } else {
                        score = max(0, score - 10)
                    }
                }
                if isButtonLike { score += 10 }
                if smallExactControl { score += 4 }
            } else if isHuge {
                score = max(0, score - 8)
            }

            score += toolbarPositionBonus(frame: frame, windowBounds: windowBounds, hints: hints)
            score += contentActionPositionBonus(frame: frame, windowBounds: windowBounds, hints: hints)

            if score >= 12 {
                if best == nil || score > best!.score || (score == best!.score && area < best!.area) {
                    best = (score, area, frame, element)
                }
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(100) {
            search(
                element: child,
                hints: hints,
                depth: depth + 1,
                windowBounds: windowBounds,
                preciseOnly: preciseOnly,
                band: band,
                actionMode: actionMode,
                best: &best
            )
        }
    }

    private func searchMessageEditor(
        element: AXUIElement,
        depth: Int,
        windowBounds: CGRect,
        best: inout (score: Int, area: CGFloat, rect: CGRect, element: AXUIElement)?
    ) {
        guard depth < 22 else { return }
        let role = normalizeLabel(elementRole(element) ?? "")
        let labels = elementLabels(element, includeValue: false).map(normalizeLabel).joined(separator: " ")
        let forbidden = ["recipient", "subject", "search", "email address", "add people", "carbon copy"]
        let forbiddenShort = ["to", "cc", "bcc"].contains { word in
            labels.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#, options: .regularExpression) != nil
        }

        var settable = DarwinBoolean(false)
        let valueIsSettable = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
        let editableRole = role.contains("axtextarea") || role.contains("axtextfield")
            || role.contains("axtextentryarea")

        if (valueIsSettable || editableRole), !forbiddenShort,
           !forbidden.contains(where: labels.contains),
           let frame = elementFrame(element, in: windowBounds) {
            let area = frame.width * frame.height
            let windowArea = max(1, windowBounds.width * windowBounds.height)
            guard frame.width >= 140, frame.height >= 36, area < windowArea * 0.55 else {
                return searchEditorChildren(
                    of: element,
                    depth: depth,
                    windowBounds: windowBounds,
                    best: &best
                )
            }
            var score = 20
            if role.contains("axtextarea") || role.contains("axtextentryarea") { score += 16 }
            if ["message", "reply", "compose", "body", "write"].contains(where: labels.contains) { score += 12 }
            if valueIsSettable { score += 8 }
            if frame.height >= 70 { score += 5 }
            // Inline compose opens in the lower reading pane — not the original email body above.
            let lowerBand = windowBounds.minY + windowBounds.height * 0.48
            if frame.midY <= lowerBand { score += 14 }
            if frame.midY > windowBounds.minY + windowBounds.height * 0.68 { score -= 18 }
            if best == nil || score > best!.score || (score == best!.score && area > best!.area) {
                best = (score, area, frame, element)
            }
        }

        searchEditorChildren(of: element, depth: depth, windowBounds: windowBounds, best: &best)
    }

    private func searchEditorChildren(
        of element: AXUIElement,
        depth: Int,
        windowBounds: CGRect,
        best: inout (score: Int, area: CGFloat, rect: CGRect, element: AXUIElement)?
    ) {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(100) {
            searchMessageEditor(
                element: child,
                depth: depth + 1,
                windowBounds: windowBounds,
                best: &best
            )
        }
    }

    // MARK: - Matching

    /// Strong phrase match; weak substring hits (e.g. "message" inside an email) score near zero.
    private func hintMatchScore(label: String, hints: [String]) -> Int {
        let label = normalizeLabel(label)
        guard !label.isEmpty, label.count < 80 else { return 0 }

        var best = 0
        for hint in hints {
            let h = normalizeLabel(hint)
            guard !h.isEmpty else { continue }

            if label == h {
                best = max(best, 30)
                continue
            }

            // "New message" vs "New message ▾"
            if label.hasPrefix(h) || h.hasPrefix(label), min(label.count, h.count) >= max(4, h.count * 2 / 3) {
                best = max(best, 24)
                continue
            }

            let hintWords = h.split(separator: " ").map(String.init).filter { $0.count >= 2 }
            if hintWords.count >= 2 {
                let labelWords = Set(label.split(separator: " ").map(String.init))
                let hitCount = hintWords.filter { labelWords.contains($0) || label.contains($0) }.count
                if hitCount == hintWords.count {
                    best = max(best, 22)
                    continue
                }
                // Matching only "message" from "new message" is not enough.
                if hitCount == 1, let only = hintWords.first(where: { label.contains($0) }),
                   Self.weakToolbarTokens.contains(only) {
                    continue
                }
            }

            // Single-token hints: require near-exact, short control label.
            if hintWords.count <= 1, h.count >= 4 {
                if label == h {
                    best = max(best, 28)
                } else if label.hasPrefix(h), label.count <= h.count + 8 {
                    best = max(best, 18)
                }
            }
        }
        return best
    }

    private static let weakToolbarTokens: Set<String> = [
        "new", "mail", "message", "email", "send", "open", "view", "home", "more", "reply"
    ]

    private func isToolbarAction(_ hints: [String], regionHint: String?) -> Bool {
        let joined = (hints + [regionHint ?? ""]).map(normalizeLabel).joined(separator: " ")
        if joined.contains("toolbar") || joined.contains("ribbon") || joined.contains("top_left") || joined.contains("toolbar_left") {
            return true
        }
        let keys = ["new message", "new mail", "new email", "compose", "send", "reply all", "forward", "capitalize", "bold", "italic"]
        return keys.contains(where: { joined.contains($0) })
            || (joined.contains("new") && joined.contains("message"))
            || (joined.contains("new") && joined.contains("mail"))
    }

    private func acceptsFrame(
        _ frame: CGRect,
        windowBounds: CGRect,
        band: ShowMeSearchBand,
        toolbarBias: Bool,
        actionMode: Bool = false
    ) -> Bool {
        guard frame.width > 4, frame.height > 4 else { return false }
        let visibleIntersection = frame.intersection(windowBounds)
        let requiredOverlap = actionMode && frame.width <= 220 && frame.height <= 72 ? 0.35 : 0.7
        guard !visibleIntersection.isNull,
              visibleIntersection.width * visibleIntersection.height >= frame.width * frame.height * requiredOverlap else {
            return false
        }

        let topBandMinY = windowBounds.maxY - windowBounds.height * 0.22
        let inToolbarBand = frame.midY >= topBandMinY

        if band == .toolbar {
            return inToolbarBand
        }

        if band == .contentActions {
            let belowChrome = frame.midY < windowBounds.maxY - windowBounds.height * 0.10
            let rightOfSidebar = frame.midX > windowBounds.minX + windowBounds.width * 0.20
            return belowChrome && rightOfSidebar
        }

        // Even in full search, reject inbox-list-looking cells for toolbar-ish steps.
        if toolbarBias {
            let leftList = frame.midX < windowBounds.minX + windowBounds.width * 0.38
            let belowToolbar = frame.midY < topBandMinY
            let rowShaped = frame.height >= 36 && frame.height <= 140 && frame.width > 120
            if leftList && belowToolbar && rowShaped {
                return false
            }
        }
        return true
    }

    private func toolbarPositionBonus(frame: CGRect, windowBounds: CGRect, hints: [String]) -> Int {
        guard isToolbarAction(hints, regionHint: nil) else { return 0 }
        let topBandMinY = windowBounds.maxY - windowBounds.height * 0.18
        if frame.midY >= topBandMinY { return 8 }
        if frame.midY >= windowBounds.maxY - windowBounds.height * 0.28 { return 3 }
        return -6
    }

    private func contentActionPositionBonus(frame: CGRect, windowBounds: CGRect, hints: [String]) -> Int {
        guard isContentAction(hints, regionHint: nil) else { return 0 }
        var bonus = 0
        // Gmail / Outlook Reply sits in the lower reading pane.
        if frame.midY < windowBounds.minY + windowBounds.height * 0.62 { bonus += 5 }
        if frame.midX > windowBounds.minX + windowBounds.width * 0.30 { bonus += 3 }
        return bonus
    }

    private func searchBand(for hints: [String]) -> ShowMeSearchBand {
        if isContentAction(hints, regionHint: nil) { return .contentActions }
        if isToolbarAction(hints, regionHint: nil) { return .toolbar }
        return .full
    }

    private func expandedActionHints(_ hints: [String]) -> [String] {
        var expanded = hints
        let joined = hints.map(normalizeLabel).joined(separator: " ")
        if containsWord("reply", in: joined) {
            expanded.append(contentsOf: ["Reply", "Respond"])
        }
        if containsWord("respond", in: joined) {
            expanded.append("Respond")
        }
        return Array(Set(expanded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    private func actionHintMatchScore(label: String, hints: [String]) -> Int {
        var score = hintMatchScore(label: label, hints: hints)
        let normalized = normalizeLabel(label)
        let wantsExactReply = hints.contains { normalizeLabel($0) == "reply" }
        if wantsExactReply && normalized.contains("reply all") { score = max(0, score - 10) }
        if wantsExactReply && normalized == "reply" { score = max(score, 32) }
        if wantsExactReply && normalized.hasPrefix("reply"), normalized.count <= 14 { score = max(score, 22) }
        if normalized.contains("reply") && normalized.contains("forward") { score = max(score, 20) }
        return score
    }

    static func isReplyClickStep(_ hints: [String]) -> Bool {
        hints.contains { hint in
            let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "reply" || normalized == "respond"
        }
    }

    private func isContentAction(_ hints: [String], regionHint: String?) -> Bool {
        let joined = (hints + [regionHint ?? ""]).map(normalizeLabel).joined(separator: " ")
        if joined.contains("reply all") || joined.contains("forward") { return false }
        return containsWord("reply", in: joined) || containsWord("respond", in: joined)
    }

    private func containsWord(_ word: String, in text: String) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func isBrowserContext(_ context: ActiveApplicationContext) -> Bool {
        let id = context.bundleID.lowercased()
        return id.contains("chrome") || id.contains("safari") || id.contains("firefox")
            || id.contains("edge") || id.contains("brave") || id.contains("arc")
    }

    private func looksLikeInboxNoise(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("@") { return true }
        if t.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true }
        if t.contains("unsubscribe") || t.contains("http://") || t.contains("https://") { return true }
        // Long subject/preview lines
        if t.count > 48 { return true }
        return false
    }

    private func pointInRect(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func elementRole(_ element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute as String) as? String
    }

    private func harvestSelectedDeep(_ element: AXUIElement, depth: Int, into selected: inout Set<String>) {
        guard depth < 10 else { return }
        collectSelected(from: element, into: &selected)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(40) {
            harvestSelectedDeep(child, depth: depth + 1, into: &selected)
        }
    }

    private func collectSelected(from element: AXUIElement, into selected: inout Set<String>) {
        let attrs = ["AXSelectedChildren", "AXSelectedRows", kAXSelectedTextAttribute as String]
        for attr in attrs {
            guard let value = copyAttribute(element, attr) else { continue }
            if let elements = value as? [AXUIElement] {
                for el in elements {
                    for label in elementLabels(el, includeValue: false) {
                        selected.insert(normalizeLabel(label))
                    }
                }
            } else if let text = value as? String, !text.isEmpty {
                selected.insert(normalizeLabel(text))
            }
        }

        if let selectedFlag = copyAttribute(element, "AXSelected") as? Bool, selectedFlag {
            for label in elementLabels(element, includeValue: false) {
                selected.insert(normalizeLabel(label))
            }
        }
    }

    private func elementLabels(_ element: AXUIElement, includeValue: Bool) -> [String] {
        var labels: [String] = []
        var attrs = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            "AXAttributedDescription",
            "AXHelp"
        ]
        if includeValue {
            attrs.append(kAXValueAttribute as String)
        }
        for attr in attrs {
            if let text = copyAttribute(element, attr) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labels.append(text)
            }
        }
        return labels
    }

    private func elementFrame(_ element: AXUIElement, in windowBounds: CGRect) -> CGRect? {
        guard let posValue = copyAttribute(element, kAXPositionAttribute as String),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(posValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 2, size.height > 2 else { return nil }
        let native = CGRect(origin: position, size: size)
        let converted = ScreenCoordinates.cocoaRect(fromQuartz: native)

        // Browser AX implementations and mixed-display arrangements can report global
        // frames in different conventions. Resolve against the exact remembered window
        // instead of assuming the primary display's coordinate system.
        let nativeOverlap = overlapRatio(native, windowBounds)
        let convertedOverlap = overlapRatio(converted, windowBounds)
        if nativeOverlap == 0, convertedOverlap == 0 { return nil }
        return convertedOverlap > nativeOverlap ? converted : native
    }

    private func overlapRatio(_ frame: CGRect, _ bounds: CGRect) -> CGFloat {
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull, frame.width > 0, frame.height > 0 else { return 0 }
        return (intersection.width * intersection.height) / (frame.width * frame.height)
    }

    private func optionalAX(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = copyAttribute(element, attribute) else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    private func inferredRegion(from hints: [String]) -> String {
        let joined = hints.map(normalizeLabel).joined(separator: " ")
        if joined.contains("new message") || joined.contains("new mail") || joined.contains("compose")
            || (joined.contains("new") && joined.contains("message")) {
            return "toolbar_left"
        }
        if joined.contains("send") {
            return "toolbar_left"
        }
        if joined.contains("to") || joined.contains("subject") || joined.contains("cc") {
            return "compose_top"
        }
        return "center"
    }

    private func regionPoint(regionHint: String?, in bounds: CGRect) -> (point: CGPoint, rect: CGRect)? {
        guard bounds.width > 10, bounds.height > 10 else { return nil }
        let hint = (regionHint ?? "center").lowercased()
        let inset = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        let point: CGPoint
        let rect: CGRect
        switch hint {
        case "menubar", "menu_bar", "menu":
            point = CGPoint(x: bounds.midX, y: bounds.maxY - 18)
            rect = CGRect(x: bounds.minX, y: bounds.maxY - 36, width: bounds.width, height: 36)
        case "ribbon", "toolbar", "top":
            point = CGPoint(x: inset.minX + inset.width * 0.12, y: bounds.maxY - bounds.height * 0.06)
            rect = CGRect(x: inset.minX, y: bounds.maxY - bounds.height * 0.12, width: inset.width * 0.35, height: bounds.height * 0.1)
        case "toolbar_left", "top_left", "compose_send":
            // Outlook "New message" / Send — top-left of main content.
            point = CGPoint(x: bounds.minX + bounds.width * 0.12, y: bounds.maxY - bounds.height * 0.055)
            rect = CGRect(
                x: bounds.minX + bounds.width * 0.04,
                y: bounds.maxY - bounds.height * 0.1,
                width: bounds.width * 0.18,
                height: bounds.height * 0.07
            )
        case "compose_top":
            point = CGPoint(x: bounds.minX + bounds.width * 0.35, y: bounds.maxY - bounds.height * 0.18)
            rect = CGRect(
                x: bounds.minX + bounds.width * 0.15,
                y: bounds.maxY - bounds.height * 0.28,
                width: bounds.width * 0.55,
                height: bounds.height * 0.12
            )
        case "bottom":
            point = CGPoint(x: inset.midX, y: bounds.minY + bounds.height * 0.1)
            rect = CGRect(x: inset.minX, y: bounds.minY, width: inset.width, height: bounds.height * 0.14)
        case "left", "sidebar", "file explorer", "explorer":
            point = CGPoint(x: bounds.minX + bounds.width * 0.1, y: inset.midY)
            rect = CGRect(x: bounds.minX, y: inset.minY, width: bounds.width * 0.22, height: inset.height)
        case "right":
            point = CGPoint(x: bounds.maxX - bounds.width * 0.12, y: inset.midY)
            rect = CGRect(x: bounds.maxX - bounds.width * 0.22, y: inset.minY, width: bounds.width * 0.2, height: inset.height)
        default:
            point = CGPoint(x: inset.midX, y: inset.midY)
            rect = inset.insetBy(dx: inset.width * 0.25, dy: inset.height * 0.25)
        }
        return (point, rect)
    }

    private func fallbackWindowBounds() -> CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func normalizeLabel(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchKeys(for step: ShowMeResolvedStep) -> [String] {
        var keys = step.targetHints.map(normalizeLabel).filter { !$0.isEmpty }
        if let done = step.doneHint, !done.isEmpty {
            keys.append(contentsOf: done.split(separator: " ").map { normalizeLabel(String($0)) }.filter { $0.count >= 4 })
        }
        // Prefer full title phrases over single weak tokens like "message".
        let title = normalizeLabel(step.title)
        if !title.isEmpty { keys.append(title) }
        return Array(Set(keys))
    }

    private func matches(_ label: String, hints: [String]) -> Bool {
        hintMatchScore(label: normalizeLabel(label), hints: hints) >= 18
    }

    private func isLooseStep(_ step: ShowMeResolvedStep) -> Bool {
        let t = step.title.lowercased() + " " + step.instruction.lowercased()
        return t.contains("look") || t.contains("focus") || t.contains("sidebar") || t.contains("explorer") || t.contains("find the")
    }

    private func looksLikeUserChoice(_ label: String) -> Bool {
        let l = normalizeLabel(label)
        if l.count < 3 || l.count > 80 { return false }
        let noise = ["window", "application", "group", "scroll", "text", "image", "button", "toolbar"]
        if noise.contains(where: { l == $0 }) { return false }
        if l.contains(".") || l.contains(" ") || l.count >= 4 { return true }
        return false
    }
}
