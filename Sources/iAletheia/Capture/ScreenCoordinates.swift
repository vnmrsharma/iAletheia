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
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }
}
