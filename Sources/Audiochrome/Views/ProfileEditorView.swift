import AppKit
import AudiochromeCore
import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome

    @State private var showColorPicker = false
    @State private var isEditingName = false
    @State private var filterViewportHeight: CGFloat = 0
    @State private var expandedFilterHeight: CGFloat = 0
    @State private var hoveringFilterRowCount = 0
    @State private var filterScrollLanes: [FilterScrollLane: CGRect] = [:]

    private enum Limits {
        static let frequency = 20.0...20_000.0
        static let q = 0.1...10.0
        static let gain = -20.0...20.0
        static let preamp = -30.0...12.0
        static let filterListMaxHeight: CGFloat = 360
        static let sliderRowSpacing: CGFloat = 8
    }

    private var expandedFilterFitsInView: Bool {
        expandedFilterHeight > 0
            && filterViewportHeight > 0
            && expandedFilterHeight <= filterViewportHeight + 1
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

            MenuGroupedSection {
                ProfileWaveformView(
                    preview: appState.eqFrequencyResponse(forIdentity: draft.identityKey),
                    color: draft.colorHex.asHexColor
                )
                .frame(height: MenuChrome.waveformHeight)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.contentInset)
                .padding(.bottom, MenuChrome.waveformBottomPadding)

                preampRow(draft)
            }

            filterList(draft)

            PlusCommandRow(title: "Add Filter") {
                popoverChrome.animatingDisclosure {
                    appState.updateProfileEditor { $0.addPeakingBand() }
                }
            }
            .padding(
                .top,
                draft.bands.isEmpty || draft.expandedBandID == draft.bands.last?.id
                    ? MenuChrome.waveformSpacing
                    : 0
            )

            Divider()
                .padding(.horizontal, MenuChrome.dividerInset)
                .padding(.top, MenuChrome.waveformSpacing)
                .padding(.bottom, MenuChrome.waveformSpacing)

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

            editorName(draft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: MenuChrome.textRowContentHeight)

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
                font: NSFont.systemFont(ofSize: MenuChrome.bodyFontSize, weight: .regular)
            )
        } q: {
            Color.clear
        } frequency: {
            Color.clear
        } gain: {
            PregainValueField(
                value: Binding(
                    get: { draft.preampDB },
                    set: { value in
                        appState.updateProfileEditor {
                            $0.preampDB = snappedPregain(value)
                        }
                    }
                ),
                range: Limits.preamp,
                format: compactGain,
                snap: snappedPregain
            )
        } trailing: {
            AutoChip(isOn: draft.isAutoPregain) {
                appState.updateProfileEditor { $0.isAutoPregain.toggle() }
            }
        }
    }

    private func filterList(_ draft: ProfileEditorDraft) -> some View {
        ScrollView(.vertical, showsIndicators: draft.bands.count > 3) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(draft.bands.enumerated()), id: \.element.id) { index, band in
                    let expanded = draft.expandedBandID == band.id
                    if index > 0, draft.expandedBandID != draft.bands[index - 1].id {
                        Divider().padding(.horizontal, MenuChrome.dividerInset)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        filterHeader(band, expanded: expanded, accent: draft.colorHex.asHexColor)
                            .contextMenu { filterDeleteMenu(band) }
                        if expanded {
                            MenuGroupedSection {
                                expandedFilterControls(band, accent: draft.colorHex.asHexColor)
                            }
                            .contextMenu { filterDeleteMenu(band) }
                        }
                    }
                    .background {
                        if expanded {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ExpandedFilterHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: Limits.filterListMaxHeight)
        .scrollDisabled(expandedFilterFitsInView && hoveringFilterRowCount > 0)
        .onPreferenceChange(ExpandedFilterHeightKey.self) { expandedFilterHeight = $0 }
        .onChange(of: draft.expandedBandID) { _, id in
            if id == nil {
                expandedFilterHeight = 0
                hoveringFilterRowCount = 0
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            filterViewportHeight = height
        }
    }

    private func filterHeader(_ band: ProfileEditorBand, expanded: Bool, accent: Color) -> some View {
        let filter = band.filter
        return CollapsedBandRow(
            onLeadingMetricsTap: {
                popoverChrome.animatingDisclosure {
                    appState.updateProfileEditor {
                        $0.expandedBandID = expanded ? nil : band.id
                    }
                }
            },
            metricsEnabled: filter.enabled,
            metricsPrimary: expanded
        ) {
            ValuePill(filter.kind.editorLabel, isEnabled: filter.enabled)
        } q: {
            Text("Q \(ProfileWriter.formatNumber(filter.q))")
        } frequency: {
            Text(compactFrequency(filter.frequencyHz))
        } gain: {
            Text(compactGain(filter.gainDB))
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
                scrollNudgesEnabled: expandedFilterFitsInView,
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
                },
                onHoverChange: { hovering in
                    hoveringFilterRowCount = max(0, hoveringFilterRowCount + (hovering ? 1 : -1))
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
            ValuePill(number: number, in: numberRange, format: format, isEnabled: isEnabled)
            FilterSlider(value: slider, in: sliderRange)
        }
        .padding(.vertical, Limits.sliderRowSpacing / 2)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: FilterScrollLaneFramesKey.self,
                    value: [lane: geo.frame(in: .named("filterEdit"))]
                )
            }
        }
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
            guard let index = draft.bands.firstIndex(where: { $0.id == id }) else { return }
            mutate(&draft.bands[index].filter)
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

    private func snappedPregain(_ db: Double) -> Double {
        (db.clamped(to: Limits.preamp) * 10).rounded() / 10
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
                .frame(width: ValuePill.standardWidth, alignment: .leading)
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

/// AUTO chip sized to a stock switch so it lines up with filter toggles.
private struct AutoChip: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("AUTO")
                .font(CollapsedColumns.font)
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isOn ? 0.10 : 0.05))
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(width: MenuChrome.switchWidth, height: ValuePill.height)
        .accessibilityLabel("Auto pregain")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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

/// Plain, click-to-edit pregain. Editing while Auto is on turns Auto off (via AppState).
private struct PregainValueField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var snap: (Double) -> Double

    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        Group {
            if isFocused {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(CollapsedColumns.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
            } else {
                Text(format(value))
                    .font(CollapsedColumns.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { isFocused = true }
            }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                text = format(value)
            } else {
                commit()
            }
        }
        .onSubmit { isFocused = false }
        .onReceive(NotificationCenter.default.publisher(for: .audiochromeDidEndTextEditing)) { _ in
            isFocused = false
        }
    }

    private func commit() {
        let cleaned = text
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(cleaned) {
            value = snap(parsed)
        }
        text = format(value)
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
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Captures the wheel over the whole row (label + pill + slider) without eating clicks.
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

/// Full expanded-filter capture so left/right padding still nudges Q / Hz / dB.
private struct FilterSectionScrollCapture: NSViewRepresentable {
    var scrollNudgesEnabled: Bool
    var lanes: [FilterScrollLane: CGRect]
    var onScrollTick: (FilterScrollLane, Int) -> Void
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> FilterSectionScrollView {
        let view = FilterSectionScrollView()
        view.scrollNudgesEnabled = scrollNudgesEnabled
        view.lanes = lanes
        view.onScrollTick = onScrollTick
        view.onHoverChange = onHoverChange
        view.clipsToBounds = false
        return view
    }

    func updateNSView(_ view: FilterSectionScrollView, context: Context) {
        view.scrollNudgesEnabled = scrollNudgesEnabled
        view.lanes = lanes
        view.onScrollTick = onScrollTick
        view.onHoverChange = onHoverChange
    }
}

private final class FilterSectionScrollView: NSView {
    var scrollNudgesEnabled = false
    var lanes: [FilterScrollLane: CGRect] = [:]
    var onScrollTick: ((FilterScrollLane, Int) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var wheelRemainder: CGFloat = 0
    private var monitor: Any?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        super.mouseExited(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
            setHovered(false)
        }
    }

    deinit {
        removeMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            guard self.scrollNudgesEnabled, self.containsMouse(of: event) else {
                return event
            }
            self.setHovered(true)
            guard let lane = self.lane(atEvent: event), let onScrollTick = self.onScrollTick else {
                return nil
            }
            let delta = FilterSectionScrollView.valueDelta(from: event)
            self.wheelRemainder += delta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
            while abs(self.wheelRemainder) >= threshold {
                let tick = self.wheelRemainder > 0 ? 1 : -1
                self.wheelRemainder -= CGFloat(tick) * threshold
                onScrollTick(lane, tick)
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

    private func setHovered(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        isHovered = hovering
        onHoverChange?(hovering)
    }

    private func containsMouse(of event: NSEvent) -> Bool {
        guard let window, bounds.width > 0, bounds.height > 0 else { return false }
        return bounds.contains(mousePoint(of: event, in: window))
    }

    private func lane(atEvent event: NSEvent) -> FilterScrollLane? {
        guard let window else { return nil }
        let point = mousePoint(of: event, in: window)
        let swiftPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        for (lane, frame) in lanes {
            let hit = CGRect(x: 0, y: frame.minY, width: bounds.width, height: max(frame.height, 1))
            if hit.contains(swiftPoint) {
                return lane
            }
        }
        return nil
    }

    private func mousePoint(of event: NSEvent, in window: NSWindow) -> NSPoint {
        if event.window === window {
            return convert(event.locationInWindow, from: nil)
        }
        if event.window == nil {
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

private struct ExpandedFilterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
