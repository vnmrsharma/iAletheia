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

private enum ShowMeSearchBand {
    case full
    /// Top strip of the window — ribbons, New message, Send, toolbars.
    case toolbar
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
        band: ShowMeSearchBand
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
            let raw = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = normalizeLabel(raw)
            guard !label.isEmpty, !looksLikeInboxNoise(raw) else { continue }

            let score = hintMatchScore(label: label, hints: hints)
            guard score >= 12 else { continue } // reject weak "message" substring hits

            let screen = ScreenCaptureService.screenRect(
                forNormalizedVisionBox: box.normalizedBounds,
                windowCocoaBounds: windowBounds
            )
            guard acceptsFrame(screen, windowBounds: windowBounds, band: band, toolbarBias: isToolbarAction(hints, regionHint: nil)) else {
                continue
            }

            let area = screen.width * screen.height
            if area > windowBounds.width * windowBounds.height * 0.08 { continue }
            if screen.height > 64 { continue }

            var ranked = score
            ranked += toolbarPositionBonus(frame: screen, windowBounds: windowBounds, hints: hints)

            if best == nil || ranked > best!.score || (ranked == best!.score && area < best!.area) {
                best = (ranked, area, screen)
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
        preciseOnly: Bool,
        band: ShowMeSearchBand
    ) -> (point: CGPoint, rect: CGRect)? {
        let app = AXUIElementCreateApplication(pid)
        var best: (score: Int, area: CGFloat, rect: CGRect)?

        if let focused = optionalAX(app, kAXFocusedWindowAttribute as String) {
            search(
                element: focused,
                hints: hints,
                depth: 0,
                windowBounds: windowBounds,
                preciseOnly: preciseOnly,
                band: band,
                best: &best
            )
        }

        if best == nil, let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] {
            for window in windows.prefix(3) {
                search(
                    element: window,
                    hints: hints,
                    depth: 0,
                    windowBounds: windowBounds,
                    preciseOnly: preciseOnly,
                    band: band,
                    best: &best
                )
                if best != nil { break }
            }
        }

        guard let best, best.score >= 12 else { return nil }
        return (pointInRect(best.rect), best.rect)
    }

    private func search(
        element: AXUIElement,
        hints: [String],
        depth: Int,
        windowBounds: CGRect,
        preciseOnly: Bool,
        band: ShowMeSearchBand,
        best: inout (score: Int, area: CGFloat, rect: CGRect)?
    ) {
        guard depth < 20 else { return }

        let role = normalizeLabel(elementRole(element) ?? "")
        // Prefer title/description for buttons; AXValue often holds email list text.
        let preferValue = role.contains("axtextfield") || role.contains("axtextarea")
        let labels = elementLabels(element, includeValue: preferValue).map(normalizeLabel)

        var score = 0
        for label in labels {
            score = max(score, hintMatchScore(label: label, hints: hints))
        }

        if score > 0, let frame = elementFrame(element) {
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
                // List cells / static rows are common false positives for "message".
                if role.contains("axstatictext") || role.contains("axcell") || role.contains("axrow") {
                    score = max(0, score - 10)
                }
                if isButtonLike { score += 10 }
                if frame.height <= 44, frame.width <= 260 { score += 4 }
            } else if isHuge {
                score = max(0, score - 8)
            }

            score += toolbarPositionBonus(frame: frame, windowBounds: windowBounds, hints: hints)

            if score >= 12 {
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
                band: band,
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
        toolbarBias: Bool
    ) -> Bool {
        guard frame.width > 4, frame.height > 4 else { return false }

        let topBandMinY = windowBounds.maxY - windowBounds.height * 0.22
        let inToolbarBand = frame.midY >= topBandMinY

        if band == .toolbar {
            return inToolbarBand
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
        if rect.width <= 200, rect.height <= 56 {
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
