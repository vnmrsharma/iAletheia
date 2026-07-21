import AppKit
import CoreGraphics
import Foundation

/// CGWindowList uses Quartz (top-left of main display). AX / NSScreen use Cocoa (bottom-left).
enum ScreenCoordinates {
    static var mainDisplayHeight: CGFloat {
        CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
    }

    static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        let h = mainDisplayHeight
        return CGRect(
            x: rect.origin.x,
            y: h - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func quartzRect(fromCocoa rect: CGRect) -> CGRect {
        let h = mainDisplayHeight
        return CGRect(
            x: rect.origin.x,
            y: h - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
        // Global Cocoa (bottom-left of main display) → Quartz (top-left of main display).
        // This conversion is correct for all screens in the standard macOS coordinate spaces.
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// Prefer screen-local conversion when the point clearly sits on a known display.
    static func quartzPointPrecise(fromCocoa point: CGPoint) -> CGPoint {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            // Quartz Y increases downward from the top of the main display.
            // Cocoa Y increases upward from the bottom of the main display.
            // Equivalent form: mainHeight - cocoaY.
            _ = screen
        }
        return quartzPoint(fromCocoa: point)
    }

    /// Converts a Quartz-global rect to Cocoa-global using the screen that contains it.
    static func cocoaRectForGlobalQuartz(_ rect: CGRect) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            let screenQuartz = quartzRect(fromCocoa: screen.frame)
            if screenQuartz.contains(center) {
                return CGRect(
                    x: rect.origin.x,
                    y: screen.frame.maxY - (rect.origin.y - screenQuartz.minY) - rect.height,
                    width: rect.width,
                    height: rect.height
                )
            }
        }
        return cocoaRect(fromQuartz: rect)
    }
}
