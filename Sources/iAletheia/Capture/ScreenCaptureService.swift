import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Vision

final class ScreenCaptureService {
    /// Captures the frontmost / specified on-screen window for `pid` (never “largest window”).
    func captureActiveWindowImage(for pid: pid_t, windowID: CGWindowID? = nil, windowBounds: CGRect? = nil) async throws -> CGImage? {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let resolvedID = windowID ?? frontmostCGWindowID(for: pid)

        // 1) Exact window ID (frontmost active window across multi-monitor setups)
        if let resolvedID,
           let image = try await captureWindowID(resolvedID, from: content) {
            return prepareForOCR(image)
        }

        // 2) Frontmost SCWindow for this PID (z-order via CG), not largest-by-area
        if let image = try await captureFrontmostWindow(from: content, pid: pid) {
            return prepareForOCR(image)
        }

        // 3) Display that contains the active window (multi-monitor safe)
        if let image = try await captureDisplayContaining(
            bounds: windowBounds,
            from: content,
            excludingOwnWindows: true
        ) {
            return prepareForOCR(image)
        }

        return nil
    }

    func ocrText(from image: CGImage) async throws -> String {
        try await recognizeText(in: image, level: .accurate)
    }

    /// Live path: try fast first, then accurate if the result is too thin.
    func ocrTextForLiveScreen(from image: CGImage) async throws -> String {
        let fast = try await recognizeText(in: image, level: .fast)
        if fast.count >= 400 { return fast }
        let accurate = try await recognizeText(in: image, level: .accurate)
        return accurate.count >= fast.count ? accurate : fast
    }

    /// Full-display capture for a specific window’s display, else primary.
    func captureMainDisplayImage(containing bounds: CGRect? = nil) async throws -> CGImage? {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let image = try await captureDisplayContaining(
            bounds: bounds,
            from: content,
            excludingOwnWindows: true
        ) else {
            return nil
        }
        return prepareForOCR(image)
    }

    func ocrTextFast(from image: CGImage) async throws -> String {
        try await recognizeText(in: image, level: .fast)
    }

    // MARK: - ScreenCaptureKit

    private func captureWindowID(_ windowID: CGWindowID, from content: SCShareableContent) async throws -> CGImage? {
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.isOnScreen }) else {
            return nil
        }
        return try await screenshot(window: window)
    }

    private func captureFrontmostWindow(from content: SCShareableContent, pid: pid_t) async throws -> CGImage? {
        guard let targetID = frontmostCGWindowID(for: pid) else {
            // Last resort for this PID only: still avoid global largest window.
            let eligible = eligibleWindows(from: content).filter { $0.owningApplication?.processID == pid }
            guard let window = eligible.first else { return nil }
            return try await screenshot(window: window)
        }
        return try await captureWindowID(targetID, from: content)
    }

    /// Frontmost on-screen window for pid (CG list is front-to-back). Never pick by largest area.
    private func frontmostCGWindowID(for pid: pid_t) -> CGWindowID? {
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
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 160, height > 160 else { continue }
            return CGWindowID(windowNumber)
        }
        return nil
    }

    private func eligibleWindows(from content: SCShareableContent) -> [SCWindow] {
        let ownBundle = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Keep ScreenCaptureKit’s ordering; do not sort by area.
        return content.windows.filter { window in
            guard window.isOnScreen else { return false }
            guard window.frame.width > 120, window.frame.height > 120 else { return false }
            let app = window.owningApplication
            if app?.processID == ownPID { return false }
            if let ownBundle, app?.bundleIdentifier == ownBundle { return false }
            if app?.applicationName == "iAletheia" { return false }
            return true
        }
    }

    private func screenshot(window: SCWindow) async throws -> CGImage {
        let maxWidth: CGFloat = 1800
        let scale = min(1.5, maxWidth / max(window.frame.width, 1))
        let config = streamConfiguration(
            width: max(1, Int(window.frame.width * scale)),
            height: max(1, Int(window.frame.height * scale))
        )
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func captureDisplayContaining(
        bounds: CGRect?,
        from content: SCShareableContent,
        excludingOwnWindows: Bool
    ) async throws -> CGImage? {
        let display = display(for: bounds, in: content) ?? content.displays.first
        guard let display else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let exclude = excludingOwnWindows
            ? content.windows.filter {
                $0.owningApplication?.processID == ownPID || $0.owningApplication?.applicationName == "iAletheia"
            }
            : []
        let filter = SCContentFilter(display: display, excludingWindows: exclude)
        let config = streamConfiguration(
            width: min(Int(display.width), 1920),
            height: min(Int(display.height), 1200)
        )
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func display(for bounds: CGRect?, in content: SCShareableContent) -> SCDisplay? {
        guard let bounds, bounds.width > 1, bounds.height > 1 else {
            return content.displays.first
        }
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        for display in content.displays {
            let frame = CGDisplayBounds(display.displayID)
            if frame.contains(mid) {
                return display
            }
        }
        // Fallback: largest overlap
        var best: (SCDisplay, CGFloat)?
        for display in content.displays {
            let frame = CGDisplayBounds(display.displayID)
            let overlap = frame.intersection(bounds)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if best == nil || area > (best?.1 ?? 0) {
                best = (display, area)
            }
        }
        return best?.0 ?? content.displays.first
    }

    // MARK: - OCR helpers

    private func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let sorted = observations.sorted { a, b in
                    let ay = a.boundingBox.midY
                    let by = b.boundingBox.midY
                    if abs(ay - by) > 0.01 { return ay > by }
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            if level == .accurate {
                request.minimumTextHeight = 0.006
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func prepareForOCR(_ image: CGImage) -> CGImage {
        let maxWidth = 1800
        guard image.width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let newWidth = maxWidth
        let newHeight = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    private func streamConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = min(max(width, 1), 1920)
        config.height = min(max(height, 1), 1200)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        if #available(macOS 15.0, *) {
            config.captureMicrophone = false
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return config
    }
}
