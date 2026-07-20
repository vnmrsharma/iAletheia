import SwiftUI

@main
struct iAletheiaApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainAppView()
                .environmentObject(appState)
                .environmentObject(appState.preferencesStore)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1140, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.preferencesStore)
        } label: {
            AppIconView(size: 18, isObserving: appState.isObserving)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EnvLoader.loadIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .iAletheiaEnsureOwlWidget, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    static let iAletheiaEnsureOwlWidget = Notification.Name("iAletheiaEnsureOwlWidget")
}
