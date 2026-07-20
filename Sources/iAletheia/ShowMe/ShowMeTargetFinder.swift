import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Finds on-screen UI targets via Accessibility so Show Me can point at real controls.
final class ShowMeTargetFinder {
    func resolve(
        hints: [String],
        regionHint: String?,
        context: ActiveApplicationContext
    ) -> (point: CGPoint, rect: CGRect)? {
        let normalizedHints = hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedHints.isEmpty,
           let hit = findInAccessibility(pid: context.pid, hints: normalizedHints) {
            return hit
        }

        // Fallback: approximate region inside the sticky user window.
        let bounds = context.windowBounds ?? fallbackWindowBounds()
        return regionPoint(regionHint: regionHint, in: bounds)
    }

    private func findInAccessibility(pid: pid_t, hints: [String]) -> (point: CGPoint, rect: CGRect)? {
        let app = AXUIElementCreateApplication(pid)
        var best: (score: Int, rect: CGRect)?

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowsRef) == .success,
           let focused = windowsRef {
            search(element: focused as! AXUIElement, hints: hints, depth: 0, best: &best)
        }

        if best == nil {
            var allWindows: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &allWindows) == .success,
               let windows = allWindows as? [AXUIElement] {
                for window in windows.prefix(3) {
                    search(element: window, hints: hints, depth: 0, best: &best)
                    if best != nil { break }
                }
            }
        }

        guard let best else { return nil }
        let center = CGPoint(x: best.rect.midX, y: best.rect.midY)
        return (center, best.rect)
    }

    private func search(
        element: AXUIElement,
        hints: [String],
        depth: Int,
        best: inout (score: Int, rect: CGRect)?
    ) {
        guard depth < 16 else { return }

        let labels = elementLabels(element)
        let lowerLabels = labels.map { $0.lowercased() }
        var score = 0
        for hint in hints {
            let h = hint.lowercased()
            if lowerLabels.contains(where: { $0 == h }) {
                score += 10
            } else if lowerLabels.contains(where: { $0.contains(h) || h.contains($0) }) {
                score += 4
            }
        }

        if score > 0, let frame = elementFrame(element) {
            if best == nil || score > best!.score {
                best = (score, frame)
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(50) {
            search(element: child, hints: hints, depth: depth + 1, best: &best)
        }
    }

    private func elementLabels(_ element: AXUIElement) -> [String] {
        var labels: [String] = []
        let attrs = [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String, "AXAttributedDescription"]
        for attr in attrs {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let text = ref as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labels.append(text)
            }
        }
        return labels
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue bridges CGPoint/CGSize from AXValue.
        if let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID() {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        } else {
            return nil
        }
        if let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        } else {
            return nil
        }
        guard size.width > 2, size.height > 2 else { return nil }
        return CGRect(origin: position, size: size)
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
            point = CGPoint(x: inset.midX, y: bounds.maxY - bounds.height * 0.12)
            rect = CGRect(x: inset.minX, y: bounds.maxY - bounds.height * 0.2, width: inset.width, height: bounds.height * 0.14)
        case "bottom":
            point = CGPoint(x: inset.midX, y: bounds.minY + bounds.height * 0.1)
            rect = CGRect(x: inset.minX, y: bounds.minY, width: inset.width, height: bounds.height * 0.14)
        case "left":
            point = CGPoint(x: bounds.minX + bounds.width * 0.12, y: inset.midY)
            rect = CGRect(x: bounds.minX, y: inset.minY, width: bounds.width * 0.2, height: inset.height)
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
        if let screen = NSScreen.main {
            return screen.visibleFrame
        }
        return CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
