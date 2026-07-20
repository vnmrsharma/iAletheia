import SwiftUI

enum AppTheme {
    // White surfaces
    static let background = Color.white
    static let surface = Color(red: 0.98, green: 0.99, blue: 1.0)       // #FAFCFF
    static let surfaceElevated = Color.white
    static let surfaceMuted = Color(red: 0.95, green: 0.97, blue: 0.99)   // #F1F5F9-ish

    // Blue primary
    static let blue = Color(red: 0.15, green: 0.39, blue: 0.92)           // #2563EB
    static let blueLight = Color(red: 0.93, green: 0.96, blue: 1.0)       // #EFF6FF
    static let blueMid = Color(red: 0.23, green: 0.51, blue: 0.96)        // #3B82F6

    // Green accent
    static let green = Color(red: 0.09, green: 0.64, blue: 0.29)          // #16A34A
    static let greenLight = Color(red: 0.94, green: 0.99, blue: 0.95)   // #F0FDF4
    static let greenMid = Color(red: 0.13, green: 0.77, blue: 0.37)       // #22C55E

    // Text
    static let textPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)    // #0F172A
    static let textSecondary = Color(red: 0.39, green: 0.45, blue: 0.55)  // #64748B
    static let textTertiary = Color(red: 0.58, green: 0.64, blue: 0.72)

    // Borders & shadows
    static let border = Color(red: 0.89, green: 0.91, blue: 0.94)
    static let borderFocus = blue.opacity(0.55)

    static let owlGlow = blueMid

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [blueLight, greenLight, background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var primaryButtonGradient: LinearGradient {
        LinearGradient(colors: [blueMid, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct ThemedBackground: View {
    var body: some View {
        AppTheme.heroGradient.ignoresSafeArea()
    }
}
