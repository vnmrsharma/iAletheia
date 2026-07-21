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

/// Resolves which app/window the user was actually looking at — even after the floating chat steals focus
/// or Mission Control / multiple Spaces shuffle z-order.
final class ActiveApplicationService {
    private let lock = NSLock()
    private var lastUserContext: ActiveApplicationContext?
    private var lastUserContextAt: Date?
    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    /// How long a remembered window stays authoritative while iAletheia holds focus.
    private let memoryTTL: TimeInterval = 15 * 60

    init() {
        startTracking()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        pollTimer?.invalidate()
    }

    // MARK: - Public API

    /// Best context for observation + live capture.
    /// When the chat/owl is focused, returns the last real user window (sticky across Spaces).
    func currentContext() -> ActiveApplicationContext? {
        if let live = probeLiveUserContext() {
            remember(live)
            return live
        }

        // iAletheia (or nothing useful) is frontmost — stick to what the user had open.
        if let remembered = rememberedContextIfValid() {
            return refresh(remembered)
        }

        return topmostNonSelfWindowContext()
    }

    /// Refresh sticky window title/bounds before Action / Show Me targeting.
    func refreshContextForAction(_ context: ActiveApplicationContext) -> ActiveApplicationContext {
        refresh(context)
    }

    /// Brings the remembered app window to the front and returns refreshed bounds.
    func activateWindow(for context: ActiveApplicationContext) -> ActiveApplicationContext? {
        guard let app = NSRunningApplication(processIdentifier: context.pid) else { return nil }
        app.activate()

        let appElement = AXUIElementCreateApplication(context.pid)
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        let targetWindow = windowElement(matching: context)
        if let targetWindow {
            _ = AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        }

        // Give Chrome / webmail a beat to repaint after focus changes.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return refreshContextForAction(context)
    }

    private func windowElement(matching context: ActiveApplicationContext) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(context.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return optionalAX(appElement, kAXFocusedWindowAttribute as String)
        }

        if let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if let match = windows.first(where: { axWindowTitle($0).localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(axWindowTitle($0)) }) {
                return match
            }
        }

        if let id = context.windowID,
           let bounds = windowMetadata(id: id)?.bounds ?? context.windowBounds {
            var best: (window: AXUIElement, overlap: CGFloat)?
            for window in windows {
                guard let frame = axWindowFrame(window, expectedBounds: bounds) else { continue }
                let overlap = overlapRatio(frame, bounds)
                if best == nil || overlap > best!.overlap {
                    best = (window, overlap)
                }
            }
            if let best, best.overlap > 0.35 { return best.window }
        }

        return optionalAX(appElement, kAXFocusedWindowAttribute as String) ?? windows.first
    }

    private func axWindowTitle(_ window: AXUIElement) -> String {
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return "" }
        return title
    }

    private func axWindowFrame(_ window: AXUIElement, expectedBounds: CGRect) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 2, size.height > 2 else { return nil }
        let native = CGRect(origin: position, size: size)
        let converted = ScreenCoordinates.cocoaRect(fromQuartz: native)
        let nativeOverlap = overlapRatio(native, expectedBounds)
        let convertedOverlap = overlapRatio(converted, expectedBounds)
        if nativeOverlap == 0, convertedOverlap == 0 { return nil }
        return convertedOverlap > nativeOverlap ? converted : native
    }

    private func overlapRatio(_ frame: CGRect, _ bounds: CGRect) -> CGFloat {
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull, frame.width > 0, frame.height > 0 else { return 0 }
        return (intersection.width * intersection.height) / (frame.width * frame.height)
    }

    private func optionalAX(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as! AXUIElement)
    }

    /// Call right before the floating chat becomes key so we lock onto the window the user was viewing.
    func rememberUserContextBeforeFocusSteal() {
        if let live = probeLiveUserContext() {
            remember(live)
            return
        }
        // Chat may already be key; keep existing memory if still valid.
        if rememberedContextIfValid() == nil, let fallback = topmostNonSelfWindowContext() {
            remember(fallback)
        }
    }

    // MARK: - Tracking

    private func startTracking() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }

        // Light poll so we keep the sticky target fresh while the user works (Spaces / clicks).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollRemember()
            }
            if let pollTimer = self.pollTimer {
                RunLoop.main.add(pollTimer, forMode: .common)
            }
            self.pollRemember()
        }
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if isSelf(app) { return }
        remember(context(from: app))
    }

    private func pollRemember() {
        guard let live = probeLiveUserContext() else { return }
        remember(live)
    }

    private func remember(_ context: ActiveApplicationContext) {
        lock.lock()
        lastUserContext = context
        lastUserContextAt = Date()
        lock.unlock()
    }

    private func rememberedContextIfValid() -> ActiveApplicationContext? {
        lock.lock()
        let remembered = lastUserContext
        let at = lastUserContextAt
        lock.unlock()

        guard let remembered, let at, Date().timeIntervalSince(at) <= memoryTTL else { return nil }
        if let id = remembered.windowID, !windowExists(id) { return nil }
        // Process still running?
        if NSRunningApplication(processIdentifier: remembered.pid) == nil { return nil }
        return remembered
    }

    // MARK: - Live probing

    private func probeLiveUserContext() -> ActiveApplicationContext? {
        if let app = NSWorkspace.shared.frontmostApplication, !isSelf(app) {
            return context(from: app)
        }
        return nil
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        let ownBundle = Bundle.main.bundleIdentifier
        let ownName = "iAletheia"
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

    /// When iAletheia panels have focus, pick the frontmost large non-iAletheia window on this Space.
    private func topmostNonSelfWindowContext() -> ActiveApplicationContext? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 200, height > 200 else { continue }

            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  !isSelf(app),
                  app.activationPolicy == .regular else { continue }

            let windowID = (info[kCGWindowNumber as String] as? UInt32).map { CGWindowID($0) }
            let quartzBounds = cgRect(from: boundsDict)
            let bounds = ScreenCoordinates.cocoaRect(fromQuartz: quartzBounds)
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

    /// Refresh title/bounds for a sticky window ID (may be on another Space).
    private func refresh(_ context: ActiveApplicationContext) -> ActiveApplicationContext {
        guard let id = context.windowID,
              let meta = windowMetadata(id: id) else {
            return context
        }
        return ActiveApplicationContext(
            bundleID: context.bundleID,
            applicationName: context.applicationName,
            windowTitle: meta.title ?? context.windowTitle,
            pid: context.pid,
            windowID: id,
            windowBounds: meta.bounds ?? context.windowBounds
        )
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
            let quartz = cgRect(from: boundsDict)
            return (CGWindowID(windowNumber), title, ScreenCoordinates.cocoaRect(fromQuartz: quartz))
        }
        return nil
    }

    /// Includes windows on other Spaces (no onScreenOnly) so sticky IDs stay valid.
    private func windowExists(_ id: CGWindowID) -> Bool {
        windowMetadata(id: id) != nil
    }

    private func windowMetadata(id: CGWindowID) -> (title: String?, bounds: CGRect?)? {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  CGWindowID(windowNumber) == id else { continue }
            let title = info[kCGWindowName as String] as? String
            let quartz = (info[kCGWindowBounds as String] as? [String: CGFloat]).map(cgRect(from:))
            let cocoa = quartz.map(ScreenCoordinates.cocoaRect(fromQuartz:))
            return (title, cocoa)
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
