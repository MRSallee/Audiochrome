import AppKit
import AudiochromeCore
import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome

    @State private var showColorPicker = false

    private enum Limits {
        static let frequency = 20.0...20_000.0
        static let q = 0.1...10.0
        static let gain = -20.0...20.0
        static let preamp = -30.0...12.0
        static let filterListMaxHeight: CGFloat = 360
        static let controlLabelWidth: CGFloat = 78
        static let valuePillMinWidth: CGFloat = 58
    }

    var body: some View {
        Group {
            if let draft = appState.profileEditor {
                editorBody(draft)
            } else {
                Color.clear.frame(height: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func editorBody(_ draft: ProfileEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(draft)

            ProfileWaveformView(
                preview: appState.eqFrequencyResponse(forIdentity: draft.identityKey),
                color: draft.colorHex.asHexColor
            )
            .frame(height: MenuChrome.waveformHeight)
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.waveformSpacing)
            .padding(.bottom, MenuChrome.waveformBottomPadding)

            preampRow(draft)

            filterList(draft)

            PlusCommandRow(title: "Add Filter") {
                popoverChrome.animatingDisclosure {
                    appState.updateProfileEditor { $0.addPeakingBand() }
                }
            }

            HStack(spacing: 8) {
                editorButton(title: "Cancel", prominent: false, action: cancel)
                editorButton(title: "Save", prominent: true, action: save)
            }
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.headerVerticalPadding)
            .padding(.bottom, MenuChrome.headerVerticalPadding)

            Divider().padding(.horizontal, MenuChrome.dividerInset)

            ControlCenterRow(title: "EQ on Squiglink", style: .command, trailing: .externalLink) {
                if let url = URL(string: "https://squig.link/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .padding(.bottom, MenuChrome.menuPadding)
        }
    }

    private func header(_ draft: ProfileEditorDraft) -> some View {
        HStack(spacing: 10) {
            Button {
                showColorPicker = true
            } label: {
                Circle()
                    .fill(draft.colorHex.asHexColor)
                    .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                HStack(spacing: 10) {
                    ForEach(ProfileColorPalette.swatches, id: \.self) { hex in
                        Circle()
                            .fill(hex.asHexColor)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if draft.colorHex.lowercased() == hex.lowercased() {
                                    Circle().strokeBorder(.primary, lineWidth: 1.5)
                                }
                            }
                            .onTapGesture {
                                appState.updateProfileEditor { $0.colorHex = hex }
                                showColorPicker = false
                            }
                    }
                }
                .padding(10)
            }

            TextField("Name", text: nameBinding(draft))
                .textFieldStyle(.plain)
                .font(MenuChrome.headerFont)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.menuPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }

    private func preampRow(_ draft: ProfileEditorDraft) -> some View {
        HStack(spacing: 10) {
            Text("Pregain")
                .font(MenuChrome.bodyFont)
                .foregroundStyle(.primary)
            Text(preampLabel(draft.preampDB))
                .font(MenuChrome.bodyFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Slider(
                value: Binding(
                    get: { draft.preampDB },
                    set: { value in
                        appState.updateProfileEditor {
                            $0.preampDB = value.clamped(to: Limits.preamp)
                        }
                    }
                ),
                in: Limits.preamp
            )
            Button("Auto") {
                appState.applyEditorAutoPregain()
            }
            .buttonStyle(.plain)
            .font(MenuChrome.bodyFont)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .frame(minHeight: MenuChrome.iconRowHeight)
    }

    private func filterList(_ draft: ProfileEditorDraft) -> some View {
        ScrollView(.vertical, showsIndicators: draft.bands.count > 3) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(draft.bands.enumerated()), id: \.element.id) { index, band in
                    let expanded = draft.expandedBandID == band.id
                    if index > 0, draft.expandedBandID != draft.bands[index - 1].id {
                        Divider().padding(.horizontal, MenuChrome.dividerInset)
                    }
                    filterHeader(band, expanded: expanded, accent: draft.colorHex.asHexColor)
                    if expanded {
                        MenuGroupedSection {
                            expandedFilterControls(band, accent: draft.colorHex.asHexColor)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: Limits.filterListMaxHeight)
    }

    private func filterHeader(_ band: ProfileEditorBand, expanded: Bool, accent: Color) -> some View {
        let filter = band.filter
        return HStack(spacing: 10) {
            Button {
                popoverChrome.animatingDisclosure {
                    appState.updateProfileEditor {
                        $0.expandedBandID = expanded ? nil : band.id
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    ValuePill(value: filter.kind.editorLabel, isEnabled: filter.enabled)
                    HStack(spacing: 0) {
                        Text("\(ProfileWriter.formatNumber(filter.q)) Q")
                        Spacer(minLength: 4)
                        Text(compactFrequency(filter.frequencyHz))
                        Spacer(minLength: 4)
                        Text(compactGain(filter.gainDB))
                    }
                    .font(MenuChrome.bodyFont)
                    .foregroundStyle(filter.enabled ? .primary : .tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .opacity(filter.enabled ? 1 : MenuChrome.permissionLockedOpacity)
                }
                .frame(minHeight: MenuChrome.textRowContentHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle(
                "",
                isOn: Binding(
                    get: { filter.enabled },
                    set: { enabled in
                        updateBand(band.id) { $0.enabled = enabled }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .focusEffectDisabled()
            .focusable(false)
            .tint(accent)
            .layoutPriority(1)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.headerVerticalPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }

    private func expandedFilterControls(_ band: ProfileEditorBand, accent: Color) -> some View {
        let filter = band.filter
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                controlLabel("Type")
                HStack(spacing: 6) {
                    ForEach(EQFilter.Kind.editorKinds, id: \.self) { kind in
                        ValuePill(
                            value: kind.editorLabel,
                            isSelected: filter.kind == kind
                        ) {
                            updateBand(band.id) { $0.kind = kind }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            sliderRow(
                title: "Q",
                pill: ProfileWriter.formatNumber(filter.q),
                accent: accent,
                value: Binding(
                    get: { filter.q },
                    set: { q in
                        updateBand(band.id) { $0.q = q.clamped(to: Limits.q) }
                    }
                ),
                range: Limits.q
            )
            sliderRow(
                title: "Freq (Hz)",
                pill: integerFrequency(filter.frequencyHz),
                accent: accent,
                value: Binding(
                    get: { log10(max(filter.frequencyHz, 20)) },
                    set: { logF in
                        updateBand(band.id) {
                            $0.frequencyHz = pow(10, logF).clamped(to: Limits.frequency)
                        }
                    }
                ),
                range: log10(Limits.frequency.lowerBound)...log10(Limits.frequency.upperBound)
            )
            sliderRow(
                title: "Gain (dB)",
                pill: ProfileWriter.formatNumber(filter.gainDB),
                accent: accent,
                value: Binding(
                    get: { filter.gainDB },
                    set: { gain in
                        updateBand(band.id) { $0.gainDB = gain.clamped(to: Limits.gain) }
                    }
                ),
                range: Limits.gain
            )

            Button("Delete Filter", role: .destructive) {
                popoverChrome.animatingDisclosure {
                    appState.updateProfileEditor { $0.removeBand(id: band.id) }
                }
            }
            .buttonStyle(.plain)
            .font(MenuChrome.bodyFont)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.headerVerticalPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }

    private func sliderRow(
        title: String,
        pill: String,
        accent: Color,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            controlLabel(title)
            ValuePill(value: pill, minWidth: Limits.valuePillMinWidth)
            Slider(value: value, in: range)
                .tint(accent)
        }
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title)
            .font(MenuChrome.headerFont)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(width: Limits.controlLabelWidth, alignment: .leading)
    }

    private func editorButton(title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(prominent ? 0.12 : 0.06))
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func nameBinding(_ draft: ProfileEditorDraft) -> Binding<String> {
        Binding(
            get: { draft.name },
            set: { name in
                appState.updateProfileEditor { $0.name = name }
            }
        )
    }

    private func updateBand(_ id: UUID, _ mutate: (inout EQFilter) -> Void) {
        appState.updateProfileEditor { draft in
            guard let index = draft.bands.firstIndex(where: { $0.id == id }) else { return }
            mutate(&draft.bands[index].filter)
        }
    }

    private func compactFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = (hz / 100).rounded() / 10
            return "\(ProfileWriter.formatNumber(khz))kHz"
        }
        return "\(ProfileWriter.formatNumber(hz))Hz"
    }

    private func integerFrequency(_ hz: Double) -> String {
        hz.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    private func compactGain(_ db: Double) -> String {
        "\(ProfileWriter.formatNumber(db))dB"
    }

    private func preampLabel(_ db: Double) -> String {
        "\(ProfileWriter.formatNumber(db)) dB"
    }

    private func save() {
        if appState.saveProfileEditor() {
            popoverChrome.dismissToHome()
        }
    }

    private func cancel() {
        appState.cancelProfileEditor()
        popoverChrome.dismissToHome()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
