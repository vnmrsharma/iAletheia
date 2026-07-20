import AppKit
import CoreGraphics
import Foundation

struct ActiveApplicationContext: Equatable {
    let bundleID: String
    let applicationName: String
    let windowTitle: String?
    let pid: pid_t
    /// Exact on-screen window to capture (frontmost for this app). Critical with multi-window / multi-display.
    let windowID: CGWindowID?
    let windowBounds: CGRect?
}

final class ActiveApplicationService {
    func currentContext() -> ActiveApplicationContext? {
        let ownBundle = Bundle.main.bundleIdentifier
        let ownName = "iAletheia"

        if let app = NSWorkspace.shared.frontmostApplication,
           !isSelf(app, ownBundle: ownBundle, ownName: ownName) {
            return context(from: app)
        }
        return topmostNonSelfWindowContext(ownBundle: ownBundle, ownName: ownName)
    }

    private func isSelf(_ app: NSRunningApplication, ownBundle: String?, ownName: String) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        if let ownBundle, let bundle = app.bundleIdentifier, bundle == ownBundle { return true }
        if let name = app.localizedName, name == ownName { return true }
        return false
    }

    private func context(from app: NSRunningApplication) -> ActiveApplicationContext {
        let bundleID = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? bundleID
        let pid = app.processIdentifier
        let front = frontmostWindow(for: pid)
        let axTitle = windowTitle(for: pid)
        let title = (front?.title?.isEmpty == false ? front?.title : nil)
            ?? axTitle
            ?? front?.title
        return ActiveApplicationContext(
            bundleID: bundleID,
            applicationName: name,
            windowTitle: title,
            pid: pid,
            windowID: front?.id,
            windowBounds: front?.bounds
        )
    }

    /// When iAletheia panels have focus, observe the frontmost large non-iAletheia window.
    private func topmostNonSelfWindowContext(ownBundle: String?, ownName: String) -> ActiveApplicationContext? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowList is ordered front-to-back — take the first eligible window, not the largest.
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 200, height > 200 else { continue }

            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  !isSelf(app, ownBundle: ownBundle, ownName: ownName),
                  app.activationPolicy == .regular else { continue }

            let windowID = (info[kCGWindowNumber as String] as? UInt32).map { CGWindowID($0) }
            let bounds = cgRect(from: boundsDict)
            let cgTitle = info[kCGWindowName as String] as? String
            let title = (cgTitle?.isEmpty == false ? cgTitle : nil) ?? windowTitle(for: ownerPID)
            return ActiveApplicationContext(
                bundleID: app.bundleIdentifier ?? "unknown",
                applicationName: app.localizedName ?? app.bundleIdentifier ?? "App",
                windowTitle: title,
                pid: ownerPID,
                windowID: windowID,
                windowBounds: bounds
            )
        }
        return nil
    }

    /// Frontmost on-screen window for a process (z-order), not the largest.
    func frontmostWindow(for pid: pid_t) -> (id: CGWindowID, title: String?, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  ownerPID != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 160, height > 160 else { continue }

            let title = info[kCGWindowName as String] as? String
            return (CGWindowID(windowNumber), title, cgRect(from: boundsDict))
        }
        return nil
    }

    private func cgRect(from dict: [String: CGFloat]) -> CGRect {
        CGRect(
            x: dict["X"] ?? 0,
            y: dict["Y"] ?? 0,
            width: dict["Width"] ?? 0,
            height: dict["Height"] ?? 0
        )
    }

    private func windowTitle(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                return title
            }
        }

        // When another app (chat) has focus, AX focused window may be nil — use frontmost CG title.
        if let front = frontmostWindow(for: pid), let title = front.title, !title.isEmpty {
            return title
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String, !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }
}
