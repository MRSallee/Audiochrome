import AppKit
import AudiochromeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    private enum SampleRateChoice: String, CaseIterable, Identifiable {
        case auto
        case rate44100
        case rate48000
        case rate96000

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .rate44100: return "44.1"
            case .rate48000: return "48"
            case .rate96000: return "96"
            }
        }

        var overrideHz: Double? {
            switch self {
            case .auto: return nil
            case .rate44100: return 44_100
            case .rate48000: return 48_000
            case .rate96000: return 96_000
            }
        }

        static func from(overrideHz: Double?) -> SampleRateChoice {
            guard let overrideHz else { return .auto }
            switch Int(overrideHz.rounded()) {
            case 44_100: return .rate44100
            case 48_000: return .rate48000
            case 96_000: return .rate96000
            default: return .auto
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AudiochromeBrandLockup()
                .padding(.horizontal, 6)

            settingsGroup {
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

            if AppConfig.showEQAccuracyDebugSettings {
                debugSettingsSection
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            appState.syncOpenAtLoginFromSystem()
            if AppConfig.showEQAccuracyDebugSettings {
                appState.refreshEngineDiagnostics()
            }
        }
    }

    @ViewBuilder
    private var debugSettingsSection: some View {
        Text("EQ Accuracy Debug")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 8)

        settingsGroup {
            settingsRow(
                title: "Tap Drift Compensation",
                subtitle: "Shipping default off. On can crush 19–20 kHz.",
                isOn: Binding(
                    get: { appState.config.debugAudio.tapDriftCompensation },
                    set: { value in updateDebug { $0.tapDriftCompensation = value } }
                )
            )
            Divider().padding(.leading, 14)
            settingsRow(
                title: "Hold Tap When EQ Off",
                subtitle: "Keeps passthrough path up during bypass sweeps.",
                isOn: Binding(
                    get: { appState.config.debugAudio.holdTapWhenBypassed },
                    set: { value in updateDebug { $0.holdTapWhenBypassed = value } }
                )
            )
            Divider().padding(.leading, 14)
            sampleRateRow
        }

        Text(appState.engineDiagnostics.summaryLine)
            .font(.system(size: 10, weight: .regular).monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }

    private var sampleRateRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EQ Design Sample Rate")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                Text("Auto = device/aggregate. Override only redesigns filters.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker(
                "",
                selection: Binding(
                    get: { SampleRateChoice.from(overrideHz: appState.config.debugAudio.eqSampleRateOverrideHz) },
                    set: { choice in
                        updateDebug { $0.eqSampleRateOverrideHz = choice.overrideHz }
                    }
                )
            ) {
                ForEach(SampleRateChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 168)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func updateDebug(_ mutate: (inout AudioEngineDebugOptions) -> Void) {
        var options = appState.config.debugAudio
        mutate(&options)
        appState.setDebugAudio(options)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
