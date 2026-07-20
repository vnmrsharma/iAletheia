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

/// Finds on-screen UI targets via Accessibility + OCR so Show Me can point at real controls.
final class ShowMeTargetFinder {
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

        if !normalizedHints.isEmpty,
           let hit = findInAccessibility(pid: context.pid, hints: normalizedHints, windowBounds: windowBounds, preciseOnly: true) {
            return hit
        }

        if !normalizedHints.isEmpty, let captureService,
           let hit = await findViaOCR(hints: normalizedHints, context: context, captureService: captureService) {
            return hit
        }

        if !normalizedHints.isEmpty,
           let hit = findInAccessibility(pid: context.pid, hints: normalizedHints, windowBounds: windowBounds, preciseOnly: false) {
            return hit
        }

        return regionPoint(regionHint: regionHint ?? inferredRegion(from: normalizedHints), in: windowBounds)
    }

    /// AX-only refresh during watching — never falls back to window center (that jerked the pointer off target).
    func resolveAXRefresh(
        hints: [String],
        context: ActiveApplicationContext
    ) -> (point: CGPoint, rect: CGRect)? {
        let normalizedHints = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedHints.isEmpty else { return nil }
        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        return findInAccessibility(pid: context.pid, hints: normalizedHints, windowBounds: windowBounds, preciseOnly: true)
            ?? findInAccessibility(pid: context.pid, hints: normalizedHints, windowBounds: windowBounds, preciseOnly: false)
    }

    /// Capture focused/selected UI labels for auto-advance + correction.
    func activitySnapshot(pid: pid_t) -> ShowMeActivitySnapshot {
        let app = AXUIElementCreateApplication(pid)
        var selected = Set<String>()
        var focused = Set<String>()
        var labels = Set<String>()

        if let focus = optionalAX(app, kAXFocusedUIElementAttribute as String) {
            for label in elementLabels(focus) {
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
            title = elementLabels(window).first
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
        captureService: ScreenCaptureService
    ) async -> (point: CGPoint, rect: CGRect)? {
        guard let image = try? await captureService.captureActiveWindowImage(
            for: context.pid,
            windowID: context.windowID,
            windowBounds: context.windowBounds
        ) else { return nil }

        guard let boxes = try? await captureService.ocrTextBoxes(from: image), !boxes.isEmpty else {
            return nil
        }

        let windowBounds = context.windowBounds ?? fallbackWindowBounds()
        var best: (score: Int, area: CGFloat, rect: CGRect)?

        for box in boxes {
            let label = normalizeLabel(box.text)
            guard !label.isEmpty else { continue }
            var score = 0
            for hint in hints {
                let h = normalizeLabel(hint)
                guard !h.isEmpty else { continue }
                if label == h {
                    score += 20
                } else if label.hasPrefix(h) || h.hasPrefix(label) {
                    score += 14
                } else if label.contains(h) || h.contains(label) {
                    // Prefer short OCR tokens matching short hints ("Send") over long paragraphs.
                    let lengthPenalty = max(0, label.count - h.count) / 8
                    score += max(2, 8 - lengthPenalty)
                }
            }
            guard score > 0 else { continue }

            let screen = ScreenCaptureService.screenRect(
                forNormalizedVisionBox: box.normalizedBounds,
                windowCocoaBounds: windowBounds
            )
            let area = screen.width * screen.height
            // Skip huge OCR blobs (whole panels).
            if area > windowBounds.width * windowBounds.height * 0.12 { continue }
            if screen.height > 80, screen.width > 220 { continue }

            if best == nil || score > best!.score || (score == best!.score && area < best!.area) {
                best = (score, area, screen)
            }
        }

        guard let best else { return nil }
        return (pointInRect(best.rect), best.rect)
    }

    // MARK: - AX search

    private func findInAccessibility(
        pid: pid_t,
        hints: [String],
        windowBounds: CGRect,
        preciseOnly: Bool
    ) -> (point: CGPoint, rect: CGRect)? {
        let app = AXUIElementCreateApplication(pid)
        var best: (score: Int, area: CGFloat, rect: CGRect)?

        if let focused = optionalAX(app, kAXFocusedWindowAttribute as String) {
            search(element: focused, hints: hints, depth: 0, windowBounds: windowBounds, preciseOnly: preciseOnly, best: &best)
        }

        if best == nil, let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] {
            for window in windows.prefix(3) {
                search(element: window, hints: hints, depth: 0, windowBounds: windowBounds, preciseOnly: preciseOnly, best: &best)
                if best != nil { break }
            }
        }

        guard let best else { return nil }
        return (pointInRect(best.rect), best.rect)
    }

    private func search(
        element: AXUIElement,
        hints: [String],
        depth: Int,
        windowBounds: CGRect,
        preciseOnly: Bool,
        best: inout (score: Int, area: CGFloat, rect: CGRect)?
    ) {
        guard depth < 20 else { return }

        let labels = elementLabels(element).map { normalizeLabel($0) }
        let role = normalizeLabel(elementRole(element) ?? "")
        var score = 0
        for hint in hints {
            let h = normalizeLabel(hint)
            if labels.contains(where: { $0 == h }) {
                score += 12
            } else if labels.contains(where: { $0.hasPrefix(h) || h.hasPrefix($0) }) {
                score += 8
            } else if labels.contains(where: { $0.contains(h) || h.contains($0) }) {
                score += 4
            }
        }

        if score > 0, let frame = elementFrame(element) {
            let area = frame.width * frame.height
            let windowArea = max(1, windowBounds.width * windowBounds.height)
            let isControl = ["axbutton", "axmenuitem", "axlink", "axcheckbox", "axradiobutton", "axpopupbutton", "axstatictext", "aximage"]
                .contains(where: { role.contains($0) || role == $0 })
            let isHuge = area > windowArea * 0.18
                || frame.width > windowBounds.width * 0.55
                || frame.height > windowBounds.height * 0.4

            if preciseOnly {
                // Web apps often expose one giant WebArea titled with nearby text — reject those.
                if isHuge && !isControl { score = 0 }
                if role.contains("axwebarea") || role.contains("axscrollarea") || (role.contains("axgroup") && isHuge) {
                    score = 0
                }
                if isControl { score += 6 }
                if frame.height <= 48, frame.width <= 280 { score += 4 }
            } else if isHuge {
                score = max(0, score - 8)
            }

            if score > 0 {
                if best == nil || score > best!.score || (score == best!.score && area < best!.area) {
                    best = (score, area, frame)
                }
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(80) {
            search(
                element: child,
                hints: hints,
                depth: depth + 1,
                windowBounds: windowBounds,
                preciseOnly: preciseOnly,
                best: &best
            )
        }
    }

    private func pointInRect(_ rect: CGRect) -> CGPoint {
        // Center of the control — reliable for buttons like Outlook Send.
        if rect.width <= 160, rect.height <= 56 {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(
            x: rect.minX + min(22, max(10, rect.width * 0.15)),
            y: rect.midY
        )
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
                    for label in elementLabels(el) {
                        selected.insert(normalizeLabel(label))
                    }
                }
            } else if let text = value as? String, !text.isEmpty {
                selected.insert(normalizeLabel(text))
            }
        }

        if let selectedFlag = copyAttribute(element, "AXSelected") as? Bool, selectedFlag {
            for label in elementLabels(element) {
                selected.insert(normalizeLabel(label))
            }
        }
    }

    private func elementLabels(_ element: AXUIElement) -> [String] {
        var labels: [String] = []
        let attrs = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            "AXAttributedDescription",
            "AXHelp"
        ]
        for attr in attrs {
            if let text = copyAttribute(element, attr) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labels.append(text)
            }
        }
        return labels
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
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
        return CGRect(origin: position, size: size)
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
        if joined.contains("send") || joined.contains("new mail") || joined.contains("compose") {
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
            point = CGPoint(x: inset.midX, y: bounds.maxY - bounds.height * 0.08)
            rect = CGRect(x: inset.minX, y: bounds.maxY - bounds.height * 0.16, width: inset.width, height: bounds.height * 0.12)
        case "toolbar_left", "top_left", "compose_send":
            // Outlook / webmail Send sits top-left of the compose pane.
            point = CGPoint(x: bounds.minX + bounds.width * 0.08, y: bounds.maxY - bounds.height * 0.07)
            rect = CGRect(
                x: bounds.minX + bounds.width * 0.02,
                y: bounds.maxY - bounds.height * 0.12,
                width: bounds.width * 0.16,
                height: bounds.height * 0.08
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
        let titleBits = step.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalizeLabel(String($0)) }.filter { $0.count >= 4 }
        keys.append(contentsOf: titleBits)
        return Array(Set(keys))
    }

    private func matches(_ label: String, hints: [String]) -> Bool {
        let l = normalizeLabel(label)
        guard !l.isEmpty else { return false }
        return hints.contains { h in
            l == h || l.contains(h) || h.contains(l) || l.hasPrefix(h) || h.hasPrefix(l)
        }
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
