import AppKit
import AudiochromeCore
import SwiftUI

@main
struct AudiochromeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar UI is owned by AppDelegate / NSStatusItem.
        // Settings scene keeps the SwiftUI app lifecycle alive without a Dock window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        appState = state
        EQStatusNotifier.shared.configure()
        statusBar = StatusBarController(appState: state)

        // Process taps / AudioDeviceStart are unreliable before the app has activated.
        // Menu-bar click worked because it activated first; mirror that at launch.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            state.startEngineAfterLaunch()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.restoreEngineIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.audioEngine.stop(reason: .appQuit)
    }
}
