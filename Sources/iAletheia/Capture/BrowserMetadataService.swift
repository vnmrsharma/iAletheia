import AppKit
import Foundation

struct BrowserMetadata {
    let url: String?
    let pageTitle: String?
}

final class BrowserMetadataService {
    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac"
    ]

    func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    func extract(for context: ActiveApplicationContext) -> BrowserMetadata {
        guard browserBundleIDs.contains(context.bundleID) else {
            return BrowserMetadata(url: nil, pageTitle: context.windowTitle)
        }

        if let safari = extractSafariURL(pid: context.pid) {
            return BrowserMetadata(url: safari, pageTitle: context.windowTitle)
        }
        if let chrome = extractViaAccessibility(pid: context.pid, attribute: "AXURL") {
            return BrowserMetadata(url: chrome, pageTitle: context.windowTitle)
        }
        if let addressBar = extractAddressBarURL(pid: context.pid) {
            return BrowserMetadata(url: addressBar, pageTitle: context.windowTitle)
        }
        // Prefer title-based guess so multi-tab Chrome still reports Gmail when that window is frontmost.
        return BrowserMetadata(url: guessURL(from: context.windowTitle), pageTitle: context.windowTitle)
    }

    private func extractSafariURL(pid: pid_t) -> String? {
        let script = """
        tell application "System Events"
            if exists (process "Safari") then
                tell process "Safari"
                    if exists window 1 then
                        return value of attribute "AXURL" of window 1
                    end if
                end tell
            end if
        end tell
        """
        return runAppleScript(script)
    }

    private func extractViaAccessibility(pid: pid_t, attribute: String) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            return urlAttribute(from: window as! AXUIElement, attribute: attribute)
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first else { return nil }
        return urlAttribute(from: window, attribute: attribute)
    }

    private func urlAttribute(from window: AXUIElement, attribute: String) -> String? {
        var urlValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &urlValue) == .success else {
            return nil
        }
        if let url = urlValue as? URL { return url.absoluteString }
        if let urlString = urlValue as? String { return urlString }
        return nil
    }

    /// Chrome/Edge often expose the omnibox as an AXTextField rather than AXURL.
    private func extractAddressBarURL(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for window in windows.prefix(2) {
            if let url = findURLInTree(window, depth: 0) {
                return url
            }
        }
        return nil
    }

    private func findURLInTree(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 8 else { return nil }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String ?? ""

        if roleString == kAXTextFieldRole as String || roleString == kAXComboBoxRole as String {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.contains("mail.google.com") {
                    return trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
                }
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return nil }
        for child in childElements.prefix(30) {
            if let url = findURLInTree(child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    private func guessURL(from title: String?) -> String? {
        guard let title else { return nil }
        if title.contains("http") { return title }
        let lower = title.lowercased()
        if lower.contains("gmail") || lower.contains("inbox") || lower.contains("@") && lower.contains("mail") {
            return "https://mail.google.com"
        }
        if lower.contains("github") {
            return "https://github.com"
        }
        return nil
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let output = script.executeAndReturnError(&error).stringValue,
              !output.isEmpty else { return nil }
        return output
    }
}
