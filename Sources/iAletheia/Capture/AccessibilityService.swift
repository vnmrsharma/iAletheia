import AppKit
import Foundation

struct AccessibilityExtractionResult {
    let text: String
    let selectedText: String?
}

final class AccessibilityService {
    func extract(
        from pid: pid_t,
        preferredWindowTitle: String? = nil,
        maxCharacters: Int = 12000
    ) -> AccessibilityExtractionResult? {
        let appElement = AXUIElementCreateApplication(pid)

        // Prefer focused window, then the window matching the frontmost title (multi-window safe).
        let windows = candidateWindows(for: appElement, preferredTitle: preferredWindowTitle)
        guard !windows.isEmpty else { return nil }

        var collected: [String] = []
        var selected: String?

        // Only read the first matching window — never merge text from background Chrome/GitHub windows.
        let window = windows[0]
        collectText(from: window, into: &collected, limit: maxCharacters)
        selected = selectedText(from: window)

        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return AccessibilityExtractionResult(text: String(text.prefix(maxCharacters)), selectedText: selected)
    }

    private func candidateWindows(for appElement: AXUIElement, preferredTitle: String?) -> [AXUIElement] {
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            return [window as! AXUIElement]
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return []
        }

        if let preferredTitle {
            let preferred = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !preferred.isEmpty {
                let matched = windows.first { window in
                    guard let t = title(of: window)?.lowercased() else { return false }
                    return t == preferred || t.contains(preferred) || preferred.contains(t)
                }
                if let matched { return [matched] }
                // Fuzzy: shared significant tokens (e.g. "Gmail", sender name)
                let tokens = preferred.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 }
                if !tokens.isEmpty {
                    let fuzzy = windows.first { window in
                        guard let t = title(of: window)?.lowercased() else { return false }
                        return tokens.contains { t.contains($0) }
                    }
                    if let fuzzy { return [fuzzy] }
                }
            }
        }

        let titled = windows.filter { window in
            guard let title = title(of: window) else { return false }
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return titled.isEmpty ? Array(windows.prefix(1)) : Array(titled.prefix(1))
    }

    private func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
    }

    private func collectText(from element: AXUIElement, into collected: inout [String], limit: Int, depth: Int = 0) {
        guard collected.joined().count < limit, depth < 22 else { return }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String ?? ""

        let textRoles: Set<String> = [
            kAXStaticTextRole as String,
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            "AXWebArea",
            "AXGroup"
        ]

        if textRoles.contains(roleString) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(text)
            }
        }

        if roleString == kAXStaticTextRole || roleString == "AXWebArea" || roleString.isEmpty {
            var desc: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc) == .success,
               let text = desc as? String, text.count > 8 {
                collected.append(text)
            }
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let text = titleRef as? String, text.count > 12 {
                collected.append(text)
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements.prefix(60) {
            collectText(from: child, into: &collected, limit: limit, depth: depth + 1)
        }
    }
}
