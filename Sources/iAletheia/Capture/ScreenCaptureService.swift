import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Vision

struct WindowCaptureResult {
    let image: CGImage
    /// Cocoa-global bounds that align with the captured image pixels.
    let cocoaBounds: CGRect
}

final class ScreenCaptureService {
    /// Captures the frontmost / specified on-screen window for `pid` (never “largest window”).
    func captureActiveWindow(for pid: pid_t, windowID: CGWindowID? = nil, windowBounds: CGRect? = nil) async throws -> WindowCaptureResult? {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let resolvedID = windowID ?? frontmostCGWindowID(for: pid)

        if let resolvedID,
           let window = content.windows.first(where: { $0.windowID == resolvedID && $0.isOnScreen }) {
            let image = try await screenshot(window: window)
            let bounds = cocoaBounds(for: window) ?? windowBounds ?? ScreenCoordinates.cocoaRectForGlobalQuartz(window.frame)
            return WindowCaptureResult(image: prepareForOCR(image), cocoaBounds: bounds)
        }

        if let targetID = frontmostCGWindowID(for: pid),
           let window = content.windows.first(where: { $0.windowID == targetID && $0.isOnScreen }) {
            let image = try await screenshot(window: window)
            let bounds = cocoaBounds(for: window) ?? windowBounds ?? ScreenCoordinates.cocoaRectForGlobalQuartz(window.frame)
            return WindowCaptureResult(image: prepareForOCR(image), cocoaBounds: bounds)
        }

        let eligible = eligibleWindows(from: content).filter { $0.owningApplication?.processID == pid }
        if let window = eligible.first {
            let image = try await screenshot(window: window)
            let bounds = cocoaBounds(for: window) ?? windowBounds ?? ScreenCoordinates.cocoaRectForGlobalQuartz(window.frame)
            return WindowCaptureResult(image: prepareForOCR(image), cocoaBounds: bounds)
        }

        if let image = try await captureDisplayContaining(
            bounds: windowBounds,
            from: content,
            excludingOwnWindows: true
        ) {
            let bounds = windowBounds ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            return WindowCaptureResult(image: prepareForOCR(image), cocoaBounds: bounds)
        }

        return nil
    }

    /// Captures the frontmost / specified on-screen window for `pid` (never “largest window”).
    func captureActiveWindowImage(for pid: pid_t, windowID: CGWindowID? = nil, windowBounds: CGRect? = nil) async throws -> CGImage? {
        try await captureActiveWindow(for: pid, windowID: windowID, windowBounds: windowBounds)?.image
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

    struct OCRTextBox {
        let text: String
        /// Normalized Vision box (origin bottom-left of the image).
        let normalizedBounds: CGRect
    }

    /// OCR with bounding boxes for Show Me pointing (web UIs like Outlook where AX is coarse).
    func ocrTextBoxes(from image: CGImage) async throws -> [OCRTextBox] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let boxes: [OCRTextBox] = observations.compactMap { obs in
                    guard let text = obs.topCandidates(1).first?.string,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return OCRTextBox(text: text, normalizedBounds: obs.boundingBox)
                }
                continuation.resume(returning: boxes)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.004
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Map a Vision normalized box (image space) onto a Cocoa window rect.
    static func screenRect(forNormalizedVisionBox box: CGRect, windowCocoaBounds: CGRect) -> CGRect {
        CGRect(
            x: windowCocoaBounds.minX + box.minX * windowCocoaBounds.width,
            y: windowCocoaBounds.minY + box.minY * windowCocoaBounds.height,
            width: max(8, box.width * windowCocoaBounds.width),
            height: max(8, box.height * windowCocoaBounds.height)
        )
    }

    // MARK: - ScreenCaptureKit

    private func cocoaBounds(for window: SCWindow) -> CGRect? {
        let quartz = window.frame
        guard quartz.width > 2, quartz.height > 2 else { return nil }
        return ScreenCoordinates.cocoaRectForGlobalQuartz(quartz)
    }

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
        // Window bounds are Cocoa; CGDisplayBounds is Quartz (top-left origin).
        let quartzBounds = ScreenCoordinates.quartzRect(fromCocoa: bounds)
        let mid = CGPoint(x: quartzBounds.midX, y: quartzBounds.midY)
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
            let overlap = frame.intersection(quartzBounds)
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

    /// JPEG base64 for vision models (keeps payloads small enough for Responses API).
    func jpegBase64(from image: CGImage, maxDimension: CGFloat = 1280, quality: CGFloat = 0.72) -> String? {
        let nsImage: NSImage
        let longest = CGFloat(max(image.width, image.height))
        if longest > maxDimension {
            let scale = maxDimension / longest
            let size = NSSize(
                width: max(1, CGFloat(image.width) * scale),
                height: max(1, CGFloat(image.height) * scale)
            )
            nsImage = NSImage(size: size)
            nsImage.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .medium
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                .draw(in: NSRect(origin: .zero, size: size))
            nsImage.unlockFocus()
        } else {
            nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return data.base64EncodedString()
    }

    /// Adds a labeled grid without changing the screenshot aspect ratio. Labels use
    /// top-left row/column coordinates (R0C0 is the top-left cell).
    func gridAnnotatedJPEGBase64(
        from image: CGImage,
        grid: VisionGridSpec,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.78
    ) -> String? {
        guard grid.rows > 0, grid.columns > 0 else { return nil }
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, maxDimension / max(1, longest))
        let size = NSSize(
            width: max(1, CGFloat(image.width) * scale),
            height: max(1, CGFloat(image.height) * scale)
        )
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))

        let path = NSBezierPath()
        path.lineWidth = max(1, size.width / 900)
        NSColor.systemYellow.withAlphaComponent(0.78).setStroke()
        for column in 1..<grid.columns {
            let x = size.width * CGFloat(column) / CGFloat(grid.columns)
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: size.height))
        }
        for row in 1..<grid.rows {
            let y = size.height * CGFloat(row) / CGFloat(grid.rows)
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: size.width, y: y))
        }
        path.stroke()

        let cellWidth = size.width / CGFloat(grid.columns)
        let cellHeight = size.height / CGFloat(grid.rows)
        let fontSize = max(9, min(15, size.width / 105))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let label = "R\(row)C\(column)" as NSString
                let x = CGFloat(column) * cellWidth + 3
                let y = size.height - CGFloat(row + 1) * cellHeight + cellHeight - fontSize - 5
                label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
        }
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return data.base64EncodedString()
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
