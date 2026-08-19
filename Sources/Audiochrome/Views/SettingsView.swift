import AppKit
import AudiochromeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome

    @State private var configSnapshot: AppConfig?
    @State private var didCommit = false

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(MenuChrome.headerFont)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: MenuChrome.textRowContentHeight)

                HeaderCommitControls(onCancel: cancel, onSave: save)
                    .layoutPriority(1)
            }
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.menuPadding)
            .padding(.bottom, MenuChrome.headerVerticalPadding)

            MenuGroupedSection {
                settingsRow(
                    title: "Open at Login",
                    isOn: Binding(
                        get: { appState.config.openAtLogin },
                        set: { appState.setOpenAtLogin($0) }
                    )
                )
                Divider().padding(.horizontal, MenuChrome.dividerInset)
                settingsRow(
                    title: "Animated Menu Bar Icon",
                    isOn: Binding(
                        get: { appState.config.animatedMenuBarIcon },
                        set: { appState.setAnimatedMenuBarIcon($0) }
                    )
                )
                Divider().padding(.horizontal, MenuChrome.dividerInset)
                settingsRow(
                    title: "Active EQ Reminders",
                    isOn: Binding(
                        get: { appState.config.activeEQReminders },
                        set: { appState.setActiveEQReminders($0) }
                    )
                )
                Divider().padding(.horizontal, MenuChrome.dividerInset)
                settingsRow(
                    title: "Custom EQ per device",
                    isOn: Binding(
                        get: { appState.config.customEQPerDevice },
                        set: { appState.setCustomEQPerDevice($0) }
                    )
                )

                if AppConfig.showEQAccuracyDebugSettings {
                    debugSettingsSection
                }
            }

            AudiochromeBrandLockup(logoHeight: MenuChrome.logoHeight, version: Self.versionLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.contentInset)
                .padding(.bottom, MenuChrome.contentInset)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            appState.syncOpenAtLoginFromSystem()
            configSnapshot = appState.config
            didCommit = false
        }
        .onDisappear {
            if !didCommit {
                revert()
            }
        }
    }

    private static var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = short?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "v—" : "v\(trimmed)"
    }

    private func save() {
        didCommit = true
        popoverChrome.dismissToHome()
    }

    private func cancel() {
        revert()
        didCommit = true
        popoverChrome.dismissToHome()
    }

    private func revert() {
        if let configSnapshot {
            appState.restoreConfig(configSnapshot)
        }
    }

    @ViewBuilder
    private var debugSettingsSection: some View {
        Text("EQ Accuracy Debug")
            .font(MenuChrome.sectionFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.sectionTopPadding)
            .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)

        settingsRow(
            title: "Tap Drift Compensation",
            subtitle: "Shipping default off. On can crush 19–20 kHz.",
            isOn: Binding(
                get: { appState.config.debugAudio.tapDriftCompensation },
                set: { value in updateDebug { $0.tapDriftCompensation = value } }
            )
        )
        Divider().padding(.horizontal, MenuChrome.dividerInset)
        settingsRow(
            title: "Hold Tap When EQ Off",
            subtitle: "Keeps passthrough path up during bypass sweeps.",
            isOn: Binding(
                get: { appState.config.debugAudio.holdTapWhenBypassed },
                set: { value in updateDebug { $0.holdTapWhenBypassed = value } }
            )
        )
        Divider().padding(.horizontal, MenuChrome.dividerInset)
        sampleRateRow

        Text(appState.engineDiagnostics.summaryLine)
            .font(.system(size: 10, weight: .regular).monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, MenuChrome.contentInset)
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
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.vertical, 8)
    }

    private func updateDebug(_ mutate: (inout AudioEngineDebugOptions) -> Void) {
        var options = appState.config.debugAudio
        mutate(&options)
        appState.setDebugAudio(options)
    }

    private func settingsRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MenuChrome.bodyFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: MenuChrome.textRowContentHeight)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .focusEffectDisabled()
                .focusable(false)
                .layoutPriority(1)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.headerVerticalPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }
}
