import AppKit
import AudiochromeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(
                title: "Open at Login",
                isOn: Binding(
                    get: { appState.config.openAtLogin },
                    set: { appState.setOpenAtLogin($0) }
                )
            )
            Divider().padding(.leading, 14)
            settingsRow(
                title: "Animated Menu Bar Icon",
                isOn: Binding(
                    get: { appState.config.animatedMenuBarIcon },
                    set: { appState.setAnimatedMenuBarIcon($0) }
                )
            )
            Divider().padding(.leading, 14)
            settingsRow(
                title: "Active EQ Reminders",
                subtitle: "Premium",
                isOn: Binding(
                    get: { appState.config.activeEQReminders },
                    set: { appState.setActiveEQReminders($0) }
                )
            )
            Divider().padding(.leading, 14)
            settingsRow(
                title: "Custom EQ per device",
                subtitle: "Premium",
                isOn: Binding(
                    get: { appState.config.customEQPerDevice },
                    set: { appState.setCustomEQPerDevice($0) }
                )
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(20)
        .frame(width: 420)
        .onAppear {
            appState.syncOpenAtLoginFromSystem()
        }
    }

    private func settingsRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .focusEffectDisabled()
                .focusable(false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private weak var appState: AppState?

    convenience init(appState: AppState) {
        let hosting = NSHostingController(rootView: SettingsView(appState: appState))
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Audiochrome Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.styleMask.remove(.resizable)
        self.init(window: window)
        self.appState = appState
        fitToContent()
    }

    func showSettings() {
        fitToContent()
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func fitToContent() {
        guard let window, let hosting = window.contentViewController as? NSHostingController<SettingsView> else {
            return
        }
        let fitting = hosting.sizeThatFits(in: NSSize(width: 420, height: 10_000))
        window.setContentSize(NSSize(width: 420, height: ceil(fitting.height)))
    }
}
