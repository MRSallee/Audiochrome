import AppKit
import AudiochromeCore
import SwiftUI

/// Live-apply editor. Cancel restores the opening snapshot. Delete with `Views/Effects`.
struct SubharmonicEditorView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @State private var linger: Displayed?

    private struct Displayed: Equatable {
        var settings: SubharmonicSettings
        var colorHex: String
        var isComparing: Bool
    }

    private var identityKey: String? {
        appState.effectsEditorIdentityKey
    }

    private var displayed: Displayed {
        linger ?? liveDisplayed
    }

    private var settings: SubharmonicSettings { displayed.settings }
    private var markColorHex: String { displayed.colorHex }

    private var liveDisplayed: Displayed {
        Displayed(
            settings: liveSettings,
            colorHex: liveColorHex,
            isComparing: appState.isSubharmonicComparing
        )
    }

    private var liveSettings: SubharmonicSettings {
        guard let identityKey else { return linger?.settings ?? .off }
        return appState.effects(forIdentity: identityKey).subharmonic
    }

    private var liveColorHex: String {
        guard let identityKey else { return linger?.colorHex ?? ProfileColorPalette.swatches[0] }
        let mapping = appState.config.mapping(forIdentity: identityKey)
        if let filename = mapping.profileFilename {
            return appState.colorHex(forProfile: filename, forIdentity: identityKey)
        }
        return mapping.colorHex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            MenuGroupedSection {
                ZStack(alignment: .topTrailing) {
                    SubharmonicWaveformView(
                        settings: settings,
                        colorHex: markColorHex,
                        isComparing: displayed.isComparing
                    )
                    .frame(height: MenuChrome.waveformHeight)

                    CompareChip(isOn: displayed.isComparing, subject: "Subharmonics") { comparing in
                        appState.setSubharmonicComparing(comparing)
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.contentInset)
                .padding(.bottom, MenuChrome.waveformSpacing)

                Text("Preset")
                    .font(MenuChrome.sectionFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                    .padding(.horizontal, MenuChrome.contentInset)
                    .padding(.top, MenuChrome.sectionTopPadding)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SubharmonicPreset.allCases) { preset in
                        EffectPresetRow(
                            kind: .subharmonic,
                            title: preset.title,
                            isSelected: settings.preset == preset
                        ) {
                            update { $0.apply(preset) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }

            detentRow(
                title: "Amount",
                subtitle: settings.amount.wetLabel,
                stops: SubharmonicAmount.allCases,
                labels: SubharmonicAmount.allCases.map(\.title),
                selection: settings.amount
            ) { amount in
                tweak { $0.amount = amount }
            }

            detentRow(
                title: "Range",
                subtitle: settings.range.bandLabel,
                stops: SubharmonicRange.allCases,
                labels: SubharmonicRange.allCases.map(\.title),
                selection: settings.range,
                showsLeadingDivider: true
            ) { range in
                tweak { $0.range = range }
            }

            lookaheadRow
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { rememberIfEditing() }
        .onChange(of: liveToken) { _, _ in
            rememberIfEditing()
        }
        .onDisappear { linger = nil }
    }

    private var liveToken: String {
        guard identityKey != nil else { return "" }
        return "\(liveSettings.signature)|\(liveSettings.preset.rawValue)|\(liveColorHex)|\(appState.isSubharmonicComparing)|\(liveSettings.lookahead)"
    }

    private func rememberIfEditing() {
        guard identityKey != nil else { return }
        linger = liveDisplayed
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Subharmonics")
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
    }

    private func detentRow<T: Equatable>(
        title: String,
        subtitle: String? = nil,
        stops: [T],
        labels: [String],
        selection: T,
        showsLeadingDivider: Bool = false,
        showsFill: Bool = true,
        set: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLeadingDivider {
                Divider()
                    .padding(.horizontal, MenuChrome.dividerInset)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(MenuChrome.sectionFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: MenuChrome.sectionRowHeight, alignment: .center)
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.sectionTopPadding)

            DetentSlider(
                stops: stops,
                labels: labels,
                selection: selection,
                showsFill: showsFill,
                onSelect: set
            )
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.bottom, 14)
        }
    }

    private var lookaheadRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, MenuChrome.dividerInset)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timing Lock")
                        .font(MenuChrome.bodyFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Adds 40ms delay to all audio.")
                        .font(Font(NSFont.systemFont(ofSize: 11, weight: .regular)))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: 1)

                Toggle("", isOn: Binding(
                    get: { settings.lookahead },
                    set: { on in update { $0.lookahead = on } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .focusEffectDisabled()
                .focusable(false)
                .layoutPriority(1)
            }
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.headerVerticalPadding)
            .padding(.bottom, MenuChrome.contentInset)
        }
    }

    private func tweak(_ mutate: (inout SubharmonicSettings) -> Void) {
        update { settings in
            mutate(&settings)
            settings.captureCustom()
        }
    }

    private func update(_ mutate: (inout SubharmonicSettings) -> Void) {
        guard let identityKey else { return }
        appState.updateSubharmonic(forIdentity: identityKey, mutate)
    }

    private func cancel() {
        appState.cancelEffectsEditor()
        popoverChrome.dismissToHome()
    }

    private func save() {
        appState.saveEffectsEditor()
        popoverChrome.dismissToHome()
    }
}
