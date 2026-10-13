import AppKit
import AudiochromeCore
import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @Environment(\.colorScheme) private var colorScheme

    @State private var showColorPicker = false
    @State private var isEditingName = false
    @State private var lingeringDraft: ProfileEditorDraft?
    @State private var filterScrollLanes: [FilterScrollLane: CGRect] = [:]
    @State private var focusedFilterLane: FilterScrollLane?
    @State private var filterHeaderHeight: CGFloat = 0
    @State private var filterExpandedBodyHeight: CGFloat = 0
    @State private var closingBandID: UUID?
    @State private var filterDisclosureBusy = false
    @State private var filterScroller = FilterListScroller()
    @State private var bothProgress: CGFloat = 1
    @State private var leftProgress: CGFloat = 0
    @State private var rightProgress: CGFloat = 0
    @State private var didSeedChannelProgress = false
    @State private var suppressScrollIndicators = false
    @State private var scrollIndicatorGeneration = 0

    private enum Limits {
        static let frequency = 20.0...20_000.0
        static let q = 0.1...10.0
        static let gain = -20.0...20.0
        static let filterListMaxHeight: CGFloat = 360
        static let sliderRowSpacing: CGFloat = 8
        static let filterDividerHeight: CGFloat = 1
        static let fallbackHeaderHeight: CGFloat = 52
        static let fallbackExpandedBodyHeight: CGFloat = 136
        static let channelSectionTopPadding: CGFloat = 4
    }

    var body: some View {
        Group {
            if let draft = appState.profileEditor ?? lingeringDraft {
                editorBody(draft)
            } else {
                Color.clear.frame(height: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            lingeringDraft = appState.profileEditor
            if let draft = appState.profileEditor { seedChannelProgressIfNeeded(draft) }
        }
        .onChange(of: appState.profileEditor) { _, new in
            if let new {
                lingeringDraft = new
                seedChannelProgressIfNeeded(new)
            }
        }
        .onDisappear {
            lingeringDraft = nil
            didSeedChannelProgress = false
        }
    }

    private func editorBody(_ draft: ProfileEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(draft)

            MenuGroupedSection {
                ZStack(alignment: .topTrailing) {
                    ProfileWaveformView(
                        preview: appState.eqFrequencyResponse(for: draft),
                        colorHex: draft.colorHex
                    )
                    .frame(height: MenuChrome.waveformHeight)

                    if canCompare(draft) {
                        CompareChip(isOn: appState.isEQComparing) { comparing in
                            appState.setEQComparing(comparing)
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                }
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.contentInset)
                .padding(.bottom, MenuChrome.waveformBottomPadding)

                preampRow(draft)
            }

            filterList(draft)

            Divider()
                .padding(.horizontal, MenuChrome.dividerInset)
                .padding(.top, MenuChrome.waveformSpacing)
                .padding(.bottom, MenuChrome.waveformSpacing)

            ControlCenterRow(title: "EQ on Squiglink", style: .command, leading: .externalLink) {
                NSWorkspace.shared.open(SquiglinkURL.editorURL(filters: draft.allEditorBands.map(\.filter)))
            }
            .padding(.bottom, MenuChrome.menuPadding)
        }
        .background { EditorTextFieldTabMonitor() }
    }

    private func canCompare(_ draft: ProfileEditorDraft) -> Bool {
        guard let active = appState.activeMappingIdentityKey else { return false }
        return appState.mappingIdentityKey(for: draft.identityKey) == active
    }

    private func header(_ draft: ProfileEditorDraft) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    showColorPicker = true
                } label: {
                    ProfileMarkView(
                        colorHex: draft.colorHex,
                        isSelected: true,
                        showsBars: false
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                    HStack(spacing: 10) {
                        ForEach(ProfileColorPalette.swatches, id: \.self) { hex in
                            Circle()
                                .fill(hex.asHexColor)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if ProfileColorPalette.canonical(draft.colorHex) == hex {
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

                editorName(draft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: MenuChrome.textRowContentHeight)
            }

            HeaderCommitControls(onCancel: cancel, onSave: save)
                .layoutPriority(1)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.menuPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }

    @ViewBuilder
    private func editorName(_ draft: ProfileEditorDraft) -> some View {
        if isEditingName {
            EditorNameField(text: nameBinding(draft)) {
                isEditingName = false
            }
        } else {
            Button {
                isEditingName = true
            } label: {
                Text(draft.name.isEmpty ? "Name" : draft.name)
                    .font(MenuChrome.headerFont)
                    .foregroundStyle(draft.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: MenuChrome.textRowContentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile name")
        }
    }

    private func preampRow(_ draft: ProfileEditorDraft) -> some View {
        CollapsedBandRow {
            AppKitLabel(
                text: "Pregain",
                font: NSFont.systemFont(ofSize: MenuChrome.bodyFontSize, weight: .regular),
                alignment: .right
            )
        } q: {
            Color.clear
        } frequency: {
            Color.clear
        } gain: {
            AppKitLabel(
                text: compactGain(draft.preampDB),
                font: CollapsedColumns.nsFont,
                color: .secondaryLabelColor,
                alignment: .right
            )
        } trailing: {
            Text("Auto")
                .font(CollapsedColumns.font)
                .foregroundStyle(.tertiary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .frame(width: MenuChrome.switchWidth, height: ValuePill.height)
                .accessibilityLabel("Pregain is automatic")
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private func filterList(_ draft: ProfileEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ProfileEditorChannel.allCases.enumerated()), id: \.element) { index, channel in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, MenuChrome.dividerInset)
                        .padding(.vertical, Limits.channelSectionTopPadding)
                }
                channelSection(channel, draft: draft)
            }
        }
        .onPreferenceChange(FilterBlockFramesKey.self) { frames in
            guard !filterDisclosureBusy else { return }
            updateMeasuredFilterHeights(frames, expandedID: draft.expandedBandID)
        }
        .onChange(of: draft.expandedBandID) { _, _ in
            focusedFilterLane = nil
        }
    }

    private func channelSection(_ channel: ProfileEditorChannel, draft: ProfileEditorDraft) -> some View {
        let bands = draft.bands(for: channel)
        let progress = progress(for: channel)
        let filtersHeight = filterContentHeight(bands: bands, expandedID: draft.expandedBandID)
        let scrollHeight = min(filtersHeight, Limits.filterListMaxHeight)
        let addPadding = addFilterTopPadding(bands: bands, expandedID: draft.expandedBandID)
        let bodyHeight = scrollHeight + addPadding + MenuChrome.iconRowHeight
        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: channel.title,
                style: .disclosure,
                trailing: progress.wrappedValue > 0.5 ? .chevronDown : .chevronRight
            ) {
                toggleChannelSection(channel, draft: draft)
            }

            VStack(alignment: .leading, spacing: 0) {
                if !bands.isEmpty {
                    ScrollViewport(showsIndicators: showsFilterScrollIndicators(filtersHeight: filtersHeight)) {
                        filterRows(bands, draft: draft)
                            .coordinateSpace(name: "filterList")
                            .background {
                                if progress.wrappedValue > 0.5 {
                                    FilterListScrollBridge {
                                        filterScroller.scrollView = $0
                                        filterScroller.applyPinnedHeight()
                                    }
                                }
                            }
                    }
                    .frame(height: scrollHeight)
                }

                PlusCommandRow(title: "Add filter") {
                    addFilter(to: channel)
                }
                .padding(.top, addPadding)
            }
            .frame(height: progress.wrappedValue * bodyHeight, alignment: .top)
            .clipped()
            .allowsHitTesting(progress.wrappedValue > 0.98)
        }
        .padding(.top, channel == .both ? Limits.channelSectionTopPadding : 0)
    }

    private func filterRows(_ bands: [ProfileEditorBand], draft: ProfileEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                let expanded = draft.expandedBandID == band.id
                let previousID = index > 0 ? bands[index - 1].id : nil
                if index > 0,
                   draft.expandedBandID != previousID,
                   closingBandID != previousID {
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                }
                VStack(alignment: .leading, spacing: 0) {
                    filterHeader(band, expanded: expanded, accent: draft.colorHex.profileColor(.ui, scheme: colorScheme))
                        .contextMenu { filterDeleteMenu(band) }
                    expandedFilterSlot(band, expanded: expanded, accent: draft.colorHex.profileColor(.ui, scheme: colorScheme))
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: FilterBlockFramesKey.self,
                            value: [band.id: geo.frame(in: .named("filterList"))]
                        )
                    }
                }
            }
        }
    }

    private func filterHeader(_ band: ProfileEditorBand, expanded: Bool, accent: Color) -> some View {
        let filter = band.filter
        return CollapsedBandRow(
            onLeadingMetricsTap: {
                toggleFilterExpanded(band, isExpanded: expanded)
            },
            metricsEnabled: filter.enabled,
            metricsPrimary: expanded
        ) {
            ValuePill(filter.kind.editorLabel, isEnabled: filter.enabled)
        } q: {
            headerMetric(
                "Q \(ProfileWriter.formatNumber(filter.q))",
                expanded: expanded,
                enabled: filter.enabled,
                alignment: .left
            )
        } frequency: {
            headerMetric(
                compactFrequency(filter.frequencyHz),
                expanded: expanded,
                enabled: filter.enabled,
                alignment: .right
            )
        } gain: {
            headerMetric(
                compactGain(filter.gainDB),
                expanded: expanded,
                enabled: filter.enabled,
                alignment: .right
            )
        } trailing: {
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
            .controlSize(.regular)
        }
    }

    /// Height-clipped slot so the controls reveal in-place instead of fading over the rows below.
    @ViewBuilder
    private func expandedFilterSlot(
        _ band: ProfileEditorBand,
        expanded: Bool,
        accent: Color
    ) -> some View {
        let bodyHeight = filterExpandedBodyHeight > 0
            ? filterExpandedBodyHeight
            : Limits.fallbackExpandedBodyHeight
        let showBody = expanded || closingBandID == band.id
        Color.clear
            .frame(height: expanded ? bodyHeight : 0)
            .overlay(alignment: .top) {
                if showBody {
                    MenuGroupedSection {
                        expandedFilterControls(band, accent: accent)
                    }
                    .frame(height: bodyHeight, alignment: .top)
                    .contextMenu { filterDeleteMenu(band) }
                }
            }
            .clipped()
            .allowsHitTesting(expanded)
    }

    private func expandedFilterControls(_ band: ProfileEditorBand, accent: Color) -> some View {
        let filter = band.filter
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                controlLabel("Type")
                HStack(spacing: 6) {
                    ForEach(EQFilter.Kind.editorKinds, id: \.self) { kind in
                        ValuePill(
                            kind.editorLabel,
                            isSelected: filter.kind == kind
                        ) {
                            updateBand(band.id) { $0.kind = kind }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Limits.sliderRowSpacing / 2)

            sliderRow(
                title: "Q",
                lane: .q,
                number: Binding(
                    get: { filter.q },
                    set: { q in
                        updateBand(band.id) { $0.q = snappedQ(q) }
                    }
                ),
                format: oneDecimal,
                numberRange: Limits.q,
                slider: Binding(
                    get: { filter.q },
                    set: { q in
                        updateBand(band.id) { $0.q = snappedQ(q) }
                    }
                ),
                sliderRange: Limits.q,
                isEnabled: filter.enabled,
                accent: accent
            )
            sliderRow(
                title: "Hz",
                lane: .hz,
                number: Binding(
                    get: { filter.frequencyHz },
                    set: { hz in
                        updateBand(band.id) { $0.frequencyHz = snappedHz(hz) }
                    }
                ),
                format: integerFrequency,
                numberRange: Limits.frequency,
                slider: Binding(
                    get: { log10(max(filter.frequencyHz, 20)) },
                    set: { logF in
                        updateBand(band.id) {
                            $0.frequencyHz = snappedHz(pow(10, logF))
                        }
                    }
                ),
                sliderRange: log10(Limits.frequency.lowerBound)...log10(Limits.frequency.upperBound),
                isEnabled: filter.enabled,
                accent: accent
            )
            sliderRow(
                title: "dB",
                lane: .db,
                number: Binding(
                    get: { filter.gainDB },
                    set: { gain in
                        updateBand(band.id) { $0.gainDB = snappedGain(gain) }
                    }
                ),
                format: oneDecimal,
                numberRange: Limits.gain,
                slider: Binding(
                    get: { filter.gainDB },
                    set: { gain in
                        updateBand(band.id) { $0.gainDB = snappedGain(gain) }
                    }
                ),
                sliderRange: Limits.gain,
                isEnabled: filter.enabled,
                accent: accent
            )
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.headerVerticalPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
        .coordinateSpace(name: "filterEdit")
        .overlay {
            FilterSectionScrollCapture(
                focusedLane: focusedFilterLane,
                lanes: filterScrollLanes,
                onScrollTick: { lane, ticks in
                    switch lane {
                    case .q:
                        updateBand(band.id) { $0.q = snappedQ($0.q + 0.1 * Double(ticks)) }
                    case .hz:
                        updateBand(band.id) {
                            $0.frequencyHz = nudgedFrequency($0.frequencyHz, ticks: ticks)
                        }
                    case .db:
                        updateBand(band.id) {
                            $0.gainDB = snappedGain($0.gainDB + 0.1 * Double(ticks))
                        }
                    }
                }
            )
            .allowsHitTesting(false)
        }
        .onPreferenceChange(FilterScrollLaneFramesKey.self) { filterScrollLanes = $0 }
    }

    private func sliderRow(
        title: String,
        lane: FilterScrollLane,
        number: Binding<Double>,
        format: @escaping (Double) -> String,
        numberRange: ClosedRange<Double>,
        slider: Binding<Double>,
        sliderRange: ClosedRange<Double>,
        isEnabled: Bool,
        accent _: Color
    ) -> some View {
        HStack(spacing: 4) {
            controlLabel(title)
            ValuePill(
                number: number,
                in: numberRange,
                format: format,
                isEnabled: isEnabled,
                onEditingChange: { editing in
                    if editing {
                        focusedFilterLane = lane
                    } else if focusedFilterLane == lane {
                        focusedFilterLane = nil
                    }
                }
            )
            FilterSlider(value: slider, in: sliderRange)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: FilterScrollLaneFramesKey.self,
                            value: [lane: geo.frame(in: .named("filterEdit"))]
                        )
                    }
                }
        }
        .padding(.vertical, Limits.sliderRowSpacing / 2)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func filterDeleteMenu(_ band: ProfileEditorBand) -> some View {
        Button("Delete Filter", role: .destructive) {
            popoverChrome.animatingDisclosure {
                appState.updateProfileEditor { $0.removeBand(id: band.id) }
            }
        }
    }

    private func controlLabel(_ title: String) -> some View {
        AppKitLabel(
            text: title,
            font: NSFont.systemFont(ofSize: MenuChrome.bodyFontSize, weight: .regular),
            alignment: .right
        )
        .frame(width: ValuePill.standardWidth, alignment: .trailing)
        .padding(.trailing, 10)
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
            draft.updateBand(id, mutate)
        }
    }

    private func progress(for channel: ProfileEditorChannel) -> Binding<CGFloat> {
        switch channel {
        case .both: return $bothProgress
        case .left: return $leftProgress
        case .right: return $rightProgress
        }
    }

    private func addFilter(to channel: ProfileEditorChannel) {
        popoverChrome.animatingDisclosure {
            appState.updateProfileEditor { $0.addPeakingBand(to: channel) }
        }
    }

    private func addFilterTopPadding(bands: [ProfileEditorBand], expandedID: UUID?) -> CGFloat {
        guard let last = bands.last, expandedID == last.id else { return 0 }
        return MenuChrome.waveformSpacing
    }

    private func filterContentHeight(bands: [ProfileEditorBand], expandedID: UUID?) -> CGFloat {
        guard !bands.isEmpty else { return 0 }
        let header = filterHeaderHeight > 0 ? filterHeaderHeight : Limits.fallbackHeaderHeight
        let body = filterExpandedBodyHeight > 0 ? filterExpandedBodyHeight : Limits.fallbackExpandedBodyHeight
        var height: CGFloat = 0
        for (index, band) in bands.enumerated() {
            if index > 0, expandedID != bands[index - 1].id {
                height += Limits.filterDividerHeight
            }
            height += header
            if expandedID == band.id {
                height += body
            }
        }
        return height
    }

    private func seedChannelProgressIfNeeded(_: ProfileEditorDraft) {
        guard !didSeedChannelProgress else { return }
        didSeedChannelProgress = true
        bothProgress = 1
        leftProgress = 0
        rightProgress = 0
    }

    private func showsFilterScrollIndicators(filtersHeight: CGFloat) -> Bool {
        guard !suppressScrollIndicators, !filterDisclosureBusy else { return false }
        return filtersHeight > Limits.filterListMaxHeight + 0.5
    }

    private func hideScrollIndicatorsDuringDisclosure() {
        suppressScrollIndicators = true
        filterScroller.setVerticalScrollerHidden(true)
        scrollIndicatorGeneration += 1
        let generation = scrollIndicatorGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PopoverChrome.disclosureDuration + 0.05))
            guard generation == scrollIndicatorGeneration else { return }
            filterScroller.setVerticalScrollerHidden(false)
            suppressScrollIndicators = false
        }
    }

    private func toggleChannelSection(_ channel: ProfileEditorChannel, draft: ProfileEditorDraft) {
        let opening = progress(for: channel).wrappedValue < 0.5
        hideScrollIndicatorsDuringDisclosure()
        popoverChrome.animatingDisclosure {
            for other in ProfileEditorChannel.allCases {
                progress(for: other).wrappedValue = (opening && other == channel) ? 1 : 0
            }
            if let id = draft.expandedBandID, draft.channel(containing: id) != (opening ? channel : nil) {
                appState.updateProfileEditor { $0.expandedBandID = nil }
            }
        }
    }

    private func snappedQ(_ q: Double) -> Double {
        (q.clamped(to: Limits.q) * 10).rounded() / 10
    }

    private func snappedHz(_ hz: Double) -> Double {
        hz.clamped(to: Limits.frequency).rounded()
    }

    private func snappedGain(_ db: Double) -> Double {
        (db.clamped(to: Limits.gain) * 10).rounded() / 10
    }

    private func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func nudgedFrequency(_ hz: Double, ticks: Int) -> Double {
        var freq = hz
        let step = ticks > 0 ? 1 : -1
        for _ in 0..<abs(ticks) {
            freq += Double(step) * squiglinkFrequencyUnit(freq)
        }
        return snappedHz(freq)
    }

    /// Squiglink `freq_unit`: 1 Hz below 100, 10 Hz below 1 kHz, 100 Hz below 10 kHz, else 1 kHz.
    private func squiglinkFrequencyUnit(_ freq: Double) -> Double {
        if freq < 100 { return 1 }
        if freq < 1_000 { return 10 }
        if freq < 10_000 { return 100 }
        return 1_000
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

    /// AppKit labels don’t interpolate through the disclosure animation, so they
    /// stay glued to the pill / switch. SwiftUI `Text` slides on a different clock.
    private func headerMetric(
        _ text: String,
        expanded: Bool,
        enabled: Bool,
        alignment: NSTextAlignment
    ) -> some View {
        let color: NSColor
        if !enabled {
            color = .tertiaryLabelColor
        } else if expanded {
            color = .labelColor
        } else {
            color = .secondaryLabelColor
        }
        return AppKitLabel(
            text: text,
            font: CollapsedColumns.nsFont,
            color: color,
            alignment: alignment
        )
    }

    private func toggleFilterExpanded(_ band: ProfileEditorBand, isExpanded: Bool) {
        focusedFilterLane = nil
        filterDisclosureBusy = true
        if isExpanded {
            closingBandID = band.id
            popoverChrome.animatingDisclosure {
                appState.updateProfileEditor { $0.expandedBandID = nil }
            }
            finishFilterDisclosure(closing: band.id)
            return
        }
        guard let draft = appState.profileEditor ?? lingeringDraft else {
            filterDisclosureBusy = false
            return
        }
        let previous = draft.expandedBandID
        closingBandID = previous
        let header = filterHeaderHeight > 0 ? filterHeaderHeight : Limits.fallbackHeaderHeight
        let body = filterExpandedBodyHeight > 0 ? filterExpandedBodyHeight : Limits.fallbackExpandedBodyHeight
        let channel = draft.channel(containing: band.id) ?? .both
        let after = PredictedFilterLayout.predict(
            bands: draft.bands(for: channel),
            expanding: band.id,
            headerHeight: header,
            expandedBodyHeight: body,
            dividerHeight: Limits.filterDividerHeight
        )
        let viewport = filterScroller.viewportHeight
        let currentOffset = filterScroller.offsetYFromTop()
        let target = after.offsetKeepingBlockVisible(
            currentOffset: currentOffset,
            viewportHeight: viewport
        )
        filterScroller.pinContentHeight(after.contentHeight)
        popoverChrome.animatingDisclosure {
            appState.updateProfileEditor { $0.expandedBandID = band.id }
        }
        if abs(target - filterScroller.offsetYFromTop()) > 0.5 {
            filterScroller.animateOffsetY(
                target,
                duration: PopoverChrome.disclosureDuration,
                predictedContentHeight: after.contentHeight
            )
        }
        finishFilterDisclosure(closing: previous)
    }

    private func finishFilterDisclosure(closing id: UUID?) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PopoverChrome.disclosureDuration))
            if let id, closingBandID == id {
                closingBandID = nil
            }
            filterScroller.clearPinnedHeight()
            filterDisclosureBusy = false
        }
    }

    private func updateMeasuredFilterHeights(_ frames: [UUID: CGRect], expandedID: UUID?) {
        if let collapsed = frames.first(where: { $0.key != expandedID && $0.key != closingBandID })?.value.height,
           collapsed > 0 {
            filterHeaderHeight = collapsed
        }
        if let expandedID, let frame = frames[expandedID], filterHeaderHeight > 0 {
            let body = frame.height - filterHeaderHeight
            if body > 0 {
                filterExpandedBodyHeight = body
            }
        }
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

/// Shared Pregain / collapsed-filter row: type (or Pregain) | Q | Hz | dB | switch (or AUTO).
private struct CollapsedBandRow<Leading: View, Q: View, F: View, G: View, Trailing: View>: View {
    var onLeadingMetricsTap: (() -> Void)?
    var metricsEnabled: Bool = true
    var metricsPrimary: Bool = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var q: () -> Q
    @ViewBuilder var frequency: () -> F
    @ViewBuilder var gain: () -> G
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let row = HStack(spacing: 8) {
            lane
                .allowsHitTesting(onLeadingMetricsTap == nil)
            trailing()
                .frame(width: MenuChrome.switchWidth, alignment: .center)
                .layoutPriority(1)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, MenuChrome.headerVerticalPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)

        if let onLeadingMetricsTap {
            ZStack {
                Button(action: onLeadingMetricsTap) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Filter")
                .accessibilityAddTraits(.isButton)

                row
            }
        } else {
            row
        }
    }

    private var lane: some View {
        HStack(spacing: 8) {
            leading()
                .frame(width: ValuePill.standardWidth, alignment: .trailing)
            HStack(spacing: 0) {
                q()
                    .frame(width: CollapsedColumns.qWidth, alignment: .leading)
                Spacer(minLength: 0)
                frequency()
                    .frame(width: CollapsedColumns.frequencyWidth, alignment: .trailing)
                Spacer(minLength: 0)
                gain()
                    .frame(width: CollapsedColumns.gainWidth, alignment: .trailing)
            }
            .font(CollapsedColumns.font)
            .foregroundStyle(
                metricsEnabled
                    ? (metricsPrimary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    : AnyShapeStyle(.tertiary)
            )
            .opacity(metricsEnabled ? 1 : MenuChrome.permissionLockedOpacity)
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: MenuChrome.textRowContentHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private enum CollapsedColumns {
    static let nsFont = NSFont.monospacedDigitSystemFont(
        ofSize: MenuChrome.bodyFontSize,
        weight: .regular
    )
    static var font: Font { Font(nsFont) }

    static let qWidth = width(of: ["Q 9.9", "Q 10", "Q 0.1"])
    static let frequencyWidth = width(of: ["19.9kHz", "18.8kHz", "999Hz", "300Hz"])
    static let gainWidth = width(of: ["-19.8dB", "-10.7dB", "-30dB"])

    private static func width(of samples: [String]) -> CGFloat {
        ceil(
            samples
                .map { ($0 as NSString).size(withAttributes: [.font: nsFont]).width }
                .max() ?? 0
        )
    }
}

/// Static label whose weight SwiftUI cannot promote.
private struct AppKitLabel: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor = .labelColor
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.isBordered = false
        field.isBezeled = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
        if field.alignment != alignment { field.alignment = alignment }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let fitting = nsView.cell?.cellSize(forBounds: NSRect(
            x: 0,
            y: 0,
            width: proposal.width ?? CGFloat.greatestFiniteMagnitude,
            height: proposal.height ?? CGFloat.greatestFiniteMagnitude
        )) ?? nsView.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? fitting.width,
            height: fitting.height
        )
    }
}

/// Borderless profile-name field; first click selects all (same as filter value pills).
private struct EditorNameField: NSViewRepresentable {
    @Binding var text: String
    var onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEndEditing: onEndEditing)
    }

    func makeNSView(context: Context) -> EditorNameNSTextField {
        let field = EditorNameNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: MenuChrome.headerFontSize, weight: .bold)
        field.textColor = .labelColor
        field.placeholderString = "Name"
        field.stringValue = text
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        field.onMovedToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleFocusAndSelectAll()
        }
        context.coordinator.scheduleFocusAndSelectAll()
        return field
    }

    func updateNSView(_ field: EditorNameNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEndEditing: () -> Void
        weak var field: EditorNameNSTextField?
        private var didClaimFocus = false
        private var acceptsEndEditing = false

        init(text: Binding<String>, onEndEditing: @escaping () -> Void) {
            self.text = text
            self.onEndEditing = onEndEditing
        }

        func scheduleFocusAndSelectAll() {
            guard !didClaimFocus else { return }
            guard let field, let window = field.window else { return }
            didClaimFocus = true
            _ = window.makeFirstResponder(field)
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field, let editor = field.currentEditor() else { return }
                editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
                self.acceptsEndEditing = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard acceptsEndEditing else { return }
            onEndEditing()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                acceptsEndEditing = true
                if let window = control.window {
                    EditorTextFieldTabOrder.focusNext(in: window, reverse: false)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                acceptsEndEditing = true
                if let window = control.window {
                    EditorTextFieldTabOrder.focusNext(in: window, reverse: true)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                acceptsEndEditing = true
                control.window?.makeFirstResponder(nil)
                onEndEditing()
                return true
            }
            return false
        }
    }
}

private final class EditorNameNSTextField: NSTextField {
    var onMovedToWindow: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let nameCell = VerticallyCenteredTextFieldCell(textCell: "")
        nameCell.isBordered = false
        nameCell.drawsBackground = false
        nameCell.isEditable = true
        nameCell.isSelectable = true
        nameCell.lineBreakMode = .byTruncatingTail
        nameCell.wraps = false
        nameCell.isScrollable = true
        nameCell.focusRingType = .none
        cell = nameCell
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow?()
        }
    }

    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuChrome.textRowContentHeight)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { selectAllText() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        selectAllText()
    }

    private func selectAllText() {
        guard let editor = currentEditor() else { return }
        editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
    }
}

/// Stock `NSSlider` knob (with click bounce). Clear fill so the track doesn’t read as progress.
private struct FilterSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>

    init(value: Binding<Double>, in range: ClosedRange<Double>) {
        self._value = value
        self.range = range
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> FilterNSSlider {
        let slider = FilterNSSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.trackFillColor = .clear
        slider.refusesFirstResponder = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: FilterNSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if abs(slider.doubleValue - value) > 0.000_001 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// Forwards wheel events so the native slider doesn’t steal list scrolling.
private final class FilterNSSlider: NSSlider {
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Tab / Shift-Tab stay on editable fields (name, Q / Hz / dB). Sliders are skipped.
enum EditorTextFieldTabOrder {
    @discardableResult
    static func focusNext(in window: NSWindow, reverse: Bool) -> Bool {
        let fields = fields(in: window)
        guard !fields.isEmpty else { return false }
        let next: NSTextField
        if let current = currentField(in: window),
           let index = fields.firstIndex(where: { $0 === current }) {
            let nextIndex = reverse
                ? (index == 0 ? fields.count - 1 : index - 1)
                : (index + 1) % fields.count
            next = fields[nextIndex]
        } else {
            next = reverse ? fields[fields.count - 1] : fields[0]
        }
        return window.makeFirstResponder(next)
    }

    static func fields(in window: NSWindow) -> [NSTextField] {
        var found: [NSTextField] = []
        collect(from: window.contentView, into: &found)
        return found.sorted { a, b in
            let ra = a.convert(a.bounds, to: nil)
            let rb = b.convert(b.bounds, to: nil)
            if abs(ra.midY - rb.midY) > 8 {
                return ra.midY > rb.midY
            }
            return ra.minX < rb.minX
        }
    }

    static func currentField(in window: NSWindow) -> NSTextField? {
        if let field = window.firstResponder as? NSTextField, field.isEditable {
            return field
        }
        if let text = window.firstResponder as? NSTextView,
           let field = text.delegate as? NSTextField,
           field.isEditable {
            return field
        }
        var view = (window.firstResponder as? NSView)?.superview
        while let current = view {
            if let field = current as? NSTextField, field.isEditable { return field }
            view = current.superview
        }
        return nil
    }

    private static func collect(from view: NSView?, into fields: inout [NSTextField]) {
        guard let view, !view.isHidden else { return }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled {
            fields.append(field)
        }
        for sub in view.subviews {
            collect(from: sub, into: &fields)
        }
    }
}

private struct EditorTextFieldTabMonitor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let window = self.view?.window, event.window === window else { return event }
                guard event.charactersIgnoringModifiers == "\t" else { return event }
                let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
                guard mods.isEmpty || mods == .shift else { return event }
                EditorTextFieldTabOrder.focusNext(in: window, reverse: mods == .shift)
                return nil
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

/// Q / Hz / dB slider lanes. Wheel nudges only the focused lane’s slider track.
private enum FilterScrollLane: Hashable {
    case q, hz, db
}

private struct FilterScrollLaneFramesKey: PreferenceKey {
    static var defaultValue: [FilterScrollLane: CGRect] = [:]

    static func reduce(
        value: inout [FilterScrollLane: CGRect],
        nextValue: () -> [FilterScrollLane: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Wheel over a slider track nudges that value only while its text field is focused.
private struct FilterSectionScrollCapture: NSViewRepresentable {
    var focusedLane: FilterScrollLane?
    var lanes: [FilterScrollLane: CGRect]
    var onScrollTick: (FilterScrollLane, Int) -> Void

    func makeNSView(context: Context) -> FilterSectionScrollView {
        let view = FilterSectionScrollView()
        view.focusedLane = focusedLane
        view.lanes = lanes
        view.onScrollTick = onScrollTick
        view.clipsToBounds = false
        return view
    }

    func updateNSView(_ view: FilterSectionScrollView, context: Context) {
        view.focusedLane = focusedLane
        view.lanes = lanes
        view.onScrollTick = onScrollTick
    }
}

private final class FilterSectionScrollView: NSView {
    var focusedLane: FilterScrollLane?
    var lanes: [FilterScrollLane: CGRect] = [:]
    var onScrollTick: ((FilterScrollLane, Int) -> Void)?

    private var wheelRemainder: CGFloat = 0
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    deinit {
        removeMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard let focusedLane = self.focusedLane,
                  self.lane(atEvent: event) == focusedLane,
                  let onScrollTick = self.onScrollTick
            else {
                return event
            }
            let delta = FilterSectionScrollView.valueDelta(from: event)
            self.wheelRemainder += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
            while abs(self.wheelRemainder) >= threshold {
                let tick = self.wheelRemainder > 0 ? 1 : -1
                self.wheelRemainder -= CGFloat(tick) * threshold
                onScrollTick(focusedLane, tick)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func lane(atEvent event: NSEvent) -> FilterScrollLane? {
        guard window != nil else { return nil }
        let point = mousePoint(of: event)
        let swiftPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        for (lane, frame) in lanes where frame.contains(swiftPoint) {
            return lane
        }
        return nil
    }

    private func mousePoint(of event: NSEvent) -> NSPoint {
        if event.window === window {
            return convert(event.locationInWindow, from: nil)
        }
        if event.window == nil, let window {
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        return NSPoint(x: -1, y: -1)
    }

    /// Physical “up” increases the value, for both natural and classic scrolling.
    private static func valueDelta(from event: NSEvent) -> CGFloat {
        var delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        if event.isDirectionInvertedFromDevice {
            delta = -delta
        }
        return delta
    }
}

private struct FilterBlockFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// After-expand list geometry so we can scroll before SwiftUI lays out the new block.
private struct PredictedFilterLayout {
    var contentHeight: CGFloat
    var blockMinY: CGFloat
    var blockHeight: CGFloat

    /// Keep the current scroll if the opened block already fits. Otherwise nudge
    /// just enough to keep the header and the new controls on screen.
    func offsetKeepingBlockVisible(currentOffset: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let maxScroll = max(0, contentHeight - viewportHeight)
        let minOffset = min(maxScroll, max(0, blockMinY + blockHeight - viewportHeight))
        let maxOffset = min(maxScroll, max(0, blockMinY))
        if minOffset > maxOffset {
            return minOffset
        }
        return min(maxOffset, max(minOffset, currentOffset))
    }

    static func predict(
        bands: [ProfileEditorBand],
        expanding: UUID,
        headerHeight: CGFloat,
        expandedBodyHeight: CGFloat,
        dividerHeight: CGFloat
    ) -> PredictedFilterLayout {
        var y: CGFloat = 0
        var blockMinY: CGFloat = 0
        let blockHeight = headerHeight + expandedBodyHeight
        for (i, band) in bands.enumerated() {
            if i > 0, expanding != bands[i - 1].id {
                y += dividerHeight
            }
            if band.id == expanding {
                blockMinY = y
                y += blockHeight
            } else {
                y += headerHeight
            }
        }
        return PredictedFilterLayout(
            contentHeight: y,
            blockMinY: blockMinY,
            blockHeight: blockHeight
        )
    }
}

@MainActor
private final class FilterListScroller {
    weak var scrollView: NSScrollView?
    private var pinnedContentHeight: CGFloat = 0

    var viewportHeight: CGFloat {
        scrollView?.contentView.bounds.height ?? 0
    }

    var contentHeight: CGFloat {
        scrollView?.documentView?.frame.height ?? 0
    }

    func offsetYFromTop() -> CGFloat {
        guard let scrollView else { return 0 }
        return offsetYFromTop(in: scrollView)
    }

    func setVerticalScrollerHidden(_ hidden: Bool) {
        guard let scrollView else { return }
        scrollView.verticalScroller?.alphaValue = hidden ? 0 : 1
        scrollView.verticalScroller?.isHidden = hidden
    }

    func pinContentHeight(_ height: CGFloat) {
        pinnedContentHeight = height
        applyPinnedHeight()
    }

    func clearPinnedHeight() {
        pinnedContentHeight = 0
    }

    func applyPinnedHeight() {
        guard pinnedContentHeight > 0, let scrollView, let document = scrollView.documentView else { return }
        let visible = offsetYFromTop(in: scrollView)
        guard document.frame.height + 0.5 < pinnedContentHeight else { return }
        var frame = document.frame
        frame.size.height = pinnedContentHeight
        document.frame = frame
        setOffsetYFromTop(visible, in: scrollView, animated: false)
    }

    func animateOffsetY(
        _ y: CGFloat,
        duration: TimeInterval,
        predictedContentHeight: CGFloat
    ) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        guard viewport > 0 else { return }
        pinContentHeight(predictedContentHeight)
        let contentH = max(predictedContentHeight, scrollView.documentView?.frame.height ?? 0)
        let clamped = min(max(0, contentH - viewport), max(0, y))
        setOffsetYFromTop(clamped, in: scrollView, animated: true, duration: duration)
    }

    private func offsetYFromTop(in scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        if clip.isFlipped {
            return clip.bounds.origin.y
        }
        let docH = scrollView.documentView?.frame.height ?? clip.bounds.height
        return docH - clip.bounds.height - clip.bounds.origin.y
    }

    private func setOffsetYFromTop(
        _ y: CGFloat,
        in scrollView: NSScrollView,
        animated: Bool,
        duration: TimeInterval = 0
    ) {
        let clip = scrollView.contentView
        let contentH = max(
            pinnedContentHeight,
            scrollView.documentView?.frame.height ?? 0
        )
        let origin = boundsOrigin(forOffsetY: y, clip: clip, contentHeight: contentH)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                clip.setBoundsOrigin(origin)
            }
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func boundsOrigin(
        forOffsetY y: CGFloat,
        clip: NSClipView,
        contentHeight: CGFloat
    ) -> NSPoint {
        let x = clip.bounds.origin.x
        if clip.isFlipped {
            return NSPoint(x: x, y: y)
        }
        return NSPoint(x: x, y: contentHeight - clip.bounds.height - y)
    }
}

private struct FilterListScrollBridge: NSViewRepresentable {
    var onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> FilterListScrollBridgeView {
        let view = FilterListScrollBridgeView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ view: FilterListScrollBridgeView, context: Context) {
        view.onResolve = onResolve
        onResolve(view.enclosingScrollView)
    }
}

private final class FilterListScrollBridgeView: NSView {
    var onResolve: ((NSScrollView?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?(enclosingScrollView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
