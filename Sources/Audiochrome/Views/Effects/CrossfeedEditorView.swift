import AppKit
import AudiochromeCore
import SwiftUI

/// Live-apply editor. Cancel restores the opening snapshot. Delete with `Views/Effects`.
struct CrossfeedEditorView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @State private var linger: Displayed?

    private struct Displayed: Equatable {
        var settings: CrossfeedSettings
        var colorHex: String
        var isComparing: Bool
    }

    private var identityKey: String? {
        appState.effectsEditorIdentityKey
    }

    private var displayed: Displayed {
        linger ?? liveDisplayed
    }

    private var settings: CrossfeedSettings { displayed.settings }
    private var markColorHex: String { displayed.colorHex }

    private var liveDisplayed: Displayed {
        Displayed(
            settings: liveSettings,
            colorHex: liveColorHex,
            isComparing: appState.isCrossfeedComparing
        )
    }

    private var liveSettings: CrossfeedSettings {
        guard let identityKey else { return linger?.settings ?? .off }
        return appState.effects(forIdentity: identityKey).crossfeed
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
                    CrossfeedWaveformView(
                        settings: settings,
                        colorHex: markColorHex,
                        isComparing: displayed.isComparing
                    )
                    .frame(height: MenuChrome.waveformHeight)

                    CompareChip(isOn: displayed.isComparing, subject: "Crossfeed") { comparing in
                        appState.setCrossfeedComparing(comparing)
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.contentInset)
                .padding(.bottom, MenuChrome.waveformSpacing)

                Text("Presets")
                    .font(MenuChrome.sectionFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                    .padding(.horizontal, MenuChrome.contentInset)
                    .padding(.top, MenuChrome.sectionTopPadding)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CrossfeedPreset.allCases) { preset in
                        EffectPresetRow(
                            kind: .crossfeed,
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
                title: "Bleed",
                subtitle: settings.bleed.differenceLabel,
                stops: CrossfeedBleed.allCases,
                labels: CrossfeedBleed.allCases.map(\.title),
                selection: settings.bleed
            ) { bleed in
                tweak { $0.bleed = bleed }
            }

            detentRow(
                title: "Range",
                subtitle: settings.range.bandLabel,
                stops: CrossfeedRange.allCases,
                labels: CrossfeedRange.allCases.map(\.title),
                selection: settings.range,
                showsLeadingDivider: true
            ) { range in
                tweak { $0.range = range }
            }

            detentRow(
                title: "Image",
                subtitle: settings.image.delayLabel,
                stops: CrossfeedImage.allCases,
                labels: CrossfeedImage.allCases.map(\.title),
                selection: settings.image,
                showsLeadingDivider: true,
                showsFill: false
            ) { image in
                tweak { $0.image = image }
            }
            .padding(.bottom, MenuChrome.contentInset)
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
        return "\(liveSettings.signature)|\(liveSettings.preset.rawValue)|\(liveColorHex)|\(appState.isCrossfeedComparing)"
    }

    private func rememberIfEditing() {
        guard identityKey != nil else { return }
        linger = liveDisplayed
    }

    // DetentSlider lives in DetentSlider.swift so Subharmonic can share it.

    private var header: some View {
        HStack(spacing: 10) {
            Text("Crossfeed")
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

    private func tweak(_ mutate: (inout CrossfeedSettings) -> Void) {
        update { settings in
            mutate(&settings)
            settings.captureCustom()
        }
    }

    private func update(_ mutate: (inout CrossfeedSettings) -> Void) {
        guard let identityKey else { return }
        appState.updateCrossfeed(forIdentity: identityKey, mutate)
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
