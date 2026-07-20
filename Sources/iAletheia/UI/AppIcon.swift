import AppKit
import SwiftUI

enum AppIcon {
    static func image(size: CGFloat = 18) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let original = NSImage(contentsOf: url) else { return nil }
        let target = NSSize(width: size, height: size)
        let resized = NSImage(size: target)
        resized.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        return resized
    }
}

struct AppIconView: View {
    var size: CGFloat = 18
    var isObserving: Bool = true

    var body: some View {
        if let nsImage = AppIcon.image(size: size) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            isObserving ? AppTheme.greenMid.opacity(0.5) : AppTheme.textTertiary.opacity(0.4),
                            lineWidth: 1.5
                        )
                }
        } else {
            Image(systemName: isObserving ? "eye.fill" : "eye")
                .foregroundStyle(isObserving ? AppTheme.green : AppTheme.textSecondary)
        }
    }
}

struct AppIconBadge: View {
    var size: CGFloat = 36
    var isObserving: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.blueLight, AppTheme.greenLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            if let nsImage = AppIcon.image(size: size * 0.72) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.72, height: size * 0.72)
                    .clipShape(Circle())
            } else {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(isObserving ? AppTheme.green : AppTheme.textSecondary)
            }
        }
    }
}
