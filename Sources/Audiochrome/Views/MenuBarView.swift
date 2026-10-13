import AudiochromeCore
import AppKit
import SwiftUI

/// Menu hierarchy mirrors Control Center Wi‑Fi:
/// active output + toggle → EQ panel → other outputs (same EQ panel when expanded) → footer.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @Environment(\.colorScheme) private var colorScheme

    /// 1 = system-default output’s EQ panel visible; 0 = collapsed (an inactive output is focused).
    @State private var activePanelProgress: CGFloat = 1
    @State private var activeOtherProfilesProgress: CGFloat = 1
    @State private var activeEffectsProgress: CGFloat = 1

    /// Which inactive output’s EQ panel is open (`nil` = none).
    @State private var expandedOtherDeviceKey: String?
    @State private var otherDevicePanelProgress: CGFloat = 0
    @State private var inactiveOtherProfilesProgress: CGFloat = 0
    @State private var inactiveEffectsProgress: CGFloat = 0

    /// Inactive outputs pulled from Other Devices this session, so turning EQ on
    /// doesn’t yank the row before the toggle is saved.
    @State private var pinnedOtherDeviceKeys: Set<String> = []

    /// 1 = “Other Devices” (unequalized outputs) disclosure open.
    @State private var otherDevicesListProgress: CGFloat = 0

    @State private var colorPickerIdentityKey: String?
    /// Intrinsic height of the scrollable column (devices + EQ), before the screen cap.
    @State private var scrollableHeight: CGFloat = 0
    @State private var renamingIdentityKey: String?
    @State private var renameText = ""
    /// Bumped each rename so the AppKit field remounts and reclaims first responder.
    @State private var renameSessionID = 0
    /// Outside-click commit is delayed so context-menu mouseUp doesn’t cancel rename.
    @State private var renameOutsideClicksEnabled = false

    private var activeDevice: AudioOutputDevice? {
        if !appState.config.customEQPerDevice {
            return appState.allAudioDevice
        }
        return appState.devices.first(where: \.isDefault)
            ?? appState.devices.first
    }

    private var otherDevices: [AudioOutputDevice] {
        guard appState.config.customEQPerDevice else { return [] }
        return appState.devices.filter { device in
            guard !device.isDefault else { return false }
            return appState.shouldListInactiveOutput(device.identityKey)
                || pinnedOtherDeviceKeys.contains(device.identityKey)
        }
    }

    /// Connected outputs without EQ enabled — reachable via “Other Devices”.
    private var unlistedDevices: [AudioOutputDevice] {
        appState.devices.filter { device in
            guard !device.isDefault else { return false }
            let listed = appState.shouldListInactiveOutput(device.identityKey)
                || pinnedOtherDeviceKeys.contains(device.identityKey)
            return !listed
        }
    }

    private var activeMapping: OutputMapping {
        appState.activeMapping ?? OutputMapping()
    }

    private var activeAccent: Color {
        guard let filename = activeMapping.profileFilename else {
            return Color(nsColor: .systemGray)
        }
        return appState.colorHex(
            forProfile: filename,
            forIdentity: activeDevice?.identityKey
        ).profileColor(.ui, scheme: colorScheme)
    }

    private var isActivePanelVisible: Bool {
        activePanelProgress > 0.5
    }

    private var isLastOtherDeviceExpanded: Bool {
        guard let last = otherDevices.last else { return false }
        return expandedOtherDeviceKey == last.identityKey && otherDevicePanelProgress > 0.5
    }

    private var scrollableColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            activeOutputHeader

            // System-default EQ panel (collapses when an inactive output is expanded).
            if let key = activeDevice?.identityKey {
                clippedEQPanel(
                    identityKey: key,
                    otherProfilesProgress: $activeOtherProfilesProgress,
                    progress: activePanelProgress
                )
            }

            if !otherDevices.isEmpty, !isActivePanelVisible {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
            }

            Group {
                ForEach(otherDevices, id: \.identityKey) { device in
                    otherDeviceSection(device)
                    if device.identityKey != otherDevices.last?.identityKey {
                        Divider().padding(.horizontal, MenuChrome.dividerInset)
                    }
                }

                if !unlistedDevices.isEmpty {
                    // Grouped EQ panel already has a bottom rule; skip when the
                    // last other device is expanded so it doesn’t double up.
                    if !otherDevices.isEmpty, !isLastOtherDeviceExpanded {
                        Divider().padding(.horizontal, MenuChrome.dividerInset)
                    }
                    otherDevicesDisclosure
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                } else if !otherDevices.isEmpty, !isLastOtherDeviceExpanded {
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                }
            }
            .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
            .disabled(appState.needsAudioPermission)
        }
    }

    private var scrollableHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: HomeScrollableHeightKey.self, value: proxy.size.height)
        }
    }

    private var footerHeight: CGFloat {
        var height = MenuChrome.waveformSpacing + MenuChrome.iconRowHeight
        height += MenuChrome.iconRowHeight
        if appState.needsAudioPermission {
            height += MenuChrome.iconRowHeight
        }
        height += MenuChrome.menuPadding
        return height
    }

    private var maxScrollableHeight: CGFloat {
        max(MenuMetrics.minMeasuredHeight, MenuMetrics.maxPanelHeight() - footerHeight)
    }

    private var shouldScrollHome: Bool {
        scrollableHeight > maxScrollableHeight + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if shouldScrollHome {
                    ScrollViewport(showsIndicators: true) {
                        scrollableColumn
                            .background { scrollableHeightReader }
                    }
                    .frame(height: maxScrollableHeight)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    scrollableColumn
                        .background { scrollableHeightReader }
                }
            }

            if shouldScrollHome {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
            }

            ControlCenterRow(title: "Settings…", style: .command) {
                popoverChrome.present(.settings)
            }
            .padding(.top, MenuChrome.waveformSpacing)
            .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
            .disabled(appState.needsAudioPermission)

            ControlCenterRow(title: "Quit", style: .command) {
                appState.quit()
            }

            if appState.needsAudioPermission {
                ControlCenterRow(title: "Quit & relaunch", style: .command) {
                    appState.quitAndRelaunch()
                }
            }
        }
        .padding(.bottom, MenuChrome.menuPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .onPreferenceChange(HomeScrollableHeightKey.self) { scrollableHeight = $0 }
        .focusEffectDisabled()
        .background {
            RenameOutsideClickMonitor(enabled: renameOutsideClicksEnabled) {
                commitRename()
            }
        }
        .onAppear {
            appState.refreshAll()
            syncRenameText()
            beginPopoverSession()
            if appState.needsAudioPermission {
                appState.retryAudioEngine()
            }
        }
        .onChange(of: popoverChrome.presentationID) { _, _ in
            // NSPopover keeps the hosting view mounted — reset pins on each open.
            endRenameIfNeeded()
            beginPopoverSession()
        }
        .onChange(of: activeDevice?.identityKey) { _, _ in
            syncRenameText()
            focusActiveOutput(animated: false)
        }
        .onChange(of: otherDevices.map(\.identityKey)) { _, keys in
            if let expandedOtherDeviceKey, !keys.contains(expandedOtherDeviceKey) {
                focusActiveOutput(animated: true)
            }
        }
        .onChange(of: unlistedDevices.count) { _, count in
            if count == 0, otherDevicesListProgress > 0.01 {
                otherDevicesListProgress = 0
            }
        }
    }

    private func beginPopoverSession() {
        pinnedOtherDeviceKeys = []
        otherDevicesListProgress = 0
        focusActiveOutput(animated: false)
    }

    // MARK: - Output headers (active + inactive share the same chrome)

    private var activeOutputHeader: some View {
        Group {
            if let device = activeDevice {
                outputHeader(
                    device,
                    isFocused: isActivePanelVisible,
                    accent: activeAccent,
                    topPadding: MenuChrome.menuPadding,
                    eqToggleBlocked: appState.needsAudioPermission,
                    onToggleExpand: {
                        if renamingIdentityKey != nil {
                            commitRename()
                        } else if !isActivePanelVisible {
                            focusActiveOutput(animated: true)
                        }
                    }
                )
            } else {
                Text("No Output")
                    .font(.system(size: MenuChrome.headerFontSize, weight: MenuChrome.headerWeight))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, MenuChrome.contentInset)
                    .padding(.top, MenuChrome.menuPadding)
                    .padding(.bottom, MenuChrome.headerVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func outputHeader(
        _ device: AudioOutputDevice,
        isFocused: Bool,
        accent: Color,
        topPadding: CGFloat = MenuChrome.headerVerticalPadding,
        eqToggleBlocked: Bool = false,
        onToggleExpand: @escaping () -> Void
    ) -> some View {
        let mapping = appState.config.mapping(forIdentity: device.identityKey)
        let isRenaming = renamingIdentityKey == device.identityKey
        let canProcess = mapping.profileFilename != nil || mapping.effects.isAudible
        let toggleDisabled = (!canProcess && !mapping.enabled) || eqToggleBlocked

        return ZStack {
            if !isRenaming {
                Button(action: onToggleExpand) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(device.name)
            }

            HStack(spacing: 10) {
                outputTitle(device, isFocused: isFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: MenuChrome.textRowContentHeight)
                    .allowsHitTesting(isRenaming)

                // Constant off + no hit testing while blocked — macOS Switch still animates
                // a rejected Binding and can write through `.disabled` alone.
                Toggle("", isOn: eqToggleBlocked
                    ? .constant(false)
                    : Binding(
                        get: { mapping.enabled },
                        set: { enabled in
                            setDeviceEQEnabled(device, enabled: enabled)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .focusEffectDisabled()
                .focusable(false)
                .disabled(toggleDisabled)
                .allowsHitTesting(!toggleDisabled)
                .tint(accent)
                .layoutPriority(1)
                .accessibilityLabel("Processing")
                .accessibilityValue(eqToggleBlocked ? "Unavailable" : (mapping.enabled ? "On" : "Off"))
                .overlay {
                    // Absorb clicks that NSSwitch still accepts while disabled.
                    if toggleDisabled {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                }
                .id("eq-toggle-\(device.identityKey)-blocked:\(eqToggleBlocked)")
            }
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, topPadding)
            .padding(.bottom, MenuChrome.headerVerticalPadding)
        }
        .contextMenu {
            Button("Rename") {
                requestRename(device)
            }
            Button("Reset") {
                endRenameIfNeeded()
                if renamingIdentityKey == device.identityKey {
                    syncRenameText()
                }
                pinnedOtherDeviceKeys.remove(device.identityKey)
                if expandedOtherDeviceKey == device.identityKey {
                    focusActiveOutput(animated: true)
                }
                appState.resetOutput(forIdentity: device.identityKey)
            }
        }
    }

    @ViewBuilder
    private func outputTitle(_ device: AudioOutputDevice, isFocused: Bool) -> some View {
        let key = device.identityKey
        let isRenaming = renamingIdentityKey == key

        if isRenaming {
            DeviceRenameField(
                text: $renameText,
                font: NSFont.systemFont(
                    ofSize: MenuChrome.headerFontSize,
                    weight: isFocused ? .bold : .regular
                ),
                onCommit: { commitRename() }
            )
            .id(renameSessionID)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MenuChrome.textRowContentHeight)
        } else {
            Text(device.name)
                .font(.system(
                    size: MenuChrome.headerFontSize,
                    weight: isFocused ? MenuChrome.headerWeight : MenuChrome.bodyWeight
                ))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 2)
                // Must shrink — `fixedSize(horizontal:)` prevented ellipses and blew the row.
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shared EQ panel clip

    private func clippedEQPanel(
        identityKey: String,
        otherProfilesProgress: Binding<CGFloat>,
        progress: CGFloat
    ) -> some View {
        let isActive = identityKey == appState.activeMappingIdentityKey
        let effectsProgress = isActive ? $activeEffectsProgress : $inactiveEffectsProgress
        let height = OutputEQPanelMetrics.height(
            appState: appState,
            identityKey: identityKey,
            otherProfilesProgress: otherProfilesProgress.wrappedValue,
            effectsProgress: effectsProgress.wrappedValue,
            showsLeadingDivider: false
        )
        return MenuGroupedSection {
            OutputEQPanel(
                identityKey: identityKey,
                otherProfilesProgress: otherProfilesProgress,
                effectsProgress: effectsProgress,
                colorPickerIdentityKey: $colorPickerIdentityKey,
                showsLeadingDivider: false,
                showsCompare: identityKey == appState.activeMappingIdentityKey
            )
        }
        .frame(height: max(0, progress) * height, alignment: .top)
        .clipped()
        .opacity(progress)
        .allowsHitTesting(progress > 0.98)
    }

    // MARK: - Other devices

    private func otherDeviceSection(_ device: AudioOutputDevice) -> some View {
        let mapping = appState.config.mapping(forIdentity: device.identityKey)
        let isExpanded = expandedOtherDeviceKey == device.identityKey
        return VStack(alignment: .leading, spacing: 0) {
            otherDeviceHeader(device, mapping: mapping, isExpanded: isExpanded)

            clippedEQPanel(
                identityKey: device.identityKey,
                otherProfilesProgress: $inactiveOtherProfilesProgress,
                progress: isExpanded ? otherDevicePanelProgress : 0
            )
        }
    }

    /// Unequalized outputs (Wi‑Fi–style “Other Networks”).
    private var otherDevicesDisclosure: some View {
        let count = unlistedDevices.count
        let scrollHeight = UnlistedDevicesMetrics.scrollHeight(count: count)
        let needsScroll = count > UnlistedDevicesMetrics.maxVisibleRows

        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: "Other devices",
                style: .disclosure,
                trailing: otherDevicesListProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let opening = otherDevicesListProgress < 0.5
                popoverChrome.animatingDisclosure {
                    otherDevicesListProgress = opening ? 1 : 0
                    if opening {
                        unpinInactiveOtherDevices()
                        activePanelProgress = 0
                        activeOtherProfilesProgress = 0
                        activeEffectsProgress = 0
                        otherDevicePanelProgress = 0
                        inactiveOtherProfilesProgress = 0
                        inactiveEffectsProgress = 0
                        colorPickerIdentityKey = nil
                    }
                }
                if opening {
                    DispatchQueue.main.asyncAfter(deadline: .now() + PopoverChrome.disclosureDuration) {
                        if otherDevicePanelProgress < 0.01 {
                            expandedOtherDeviceKey = nil
                        }
                    }
                }
            }

            ScrollViewport(showsIndicators: needsScroll) {
                VStack(alignment: .leading, spacing: UnlistedDevicesMetrics.rowSpacing) {
                    ForEach(unlistedDevices, id: \.identityKey) { device in
                        if appState.config.customEQPerDevice {
                            ControlCenterRow(title: device.name, style: .listItem) {
                                selectUnlistedDevice(device)
                            }
                        } else {
                            // Shared EQ mode: inventory only — no select / expand / rename.
                            ControlCenterRow(title: device.name, style: .listItem)
                        }
                    }
                }
            }
            .frame(height: otherDevicesListProgress * scrollHeight, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)
            .clipped()
            .opacity(otherDevicesListProgress)
            .allowsHitTesting(otherDevicesListProgress > 0.98)
        }
        // Match Available Profiles section chrome (padding above/below the disclosure).
        .padding(.vertical, MenuChrome.otherProfilesSectionVerticalPadding)
    }

    private func selectUnlistedDevice(_ device: AudioOutputDevice) {
        pinInspectedOtherDevice(device.identityKey)
        focusOtherDevice(device, animated: true)
    }

    private func otherDeviceHeader(
        _ device: AudioOutputDevice,
        mapping: OutputMapping,
        isExpanded: Bool
    ) -> some View {
        outputHeader(
            device,
            isFocused: isExpanded,
            accent: Color(nsColor: .systemGray),
            topPadding: MenuChrome.headerVerticalPadding,
            onToggleExpand: {
                if renamingIdentityKey != nil {
                    commitRename()
                    return
                }
                toggleOtherDevice(device)
            }
        )
    }

    private func toggleOtherDevice(_ device: AudioOutputDevice) {
        let key = device.identityKey
        if expandedOtherDeviceKey == key, otherDevicePanelProgress > 0.5 {
            focusActiveOutput(animated: true)
            return
        }
        focusOtherDevice(device, animated: true)
    }

    /// B↔C list membership (main list vs Other devices) has to animate and re-anchor
    /// or the panel lands short and dropped below the status item.
    private func setDeviceEQEnabled(_ device: AudioOutputDevice, enabled: Bool) {
        let isActive = device.identityKey == activeDevice?.identityKey
        if !isActive, !enabled, expandedOtherDeviceKey == device.identityKey {
            pinInspectedOtherDevice(device.identityKey)
        }
        if isActive {
            appState.setEnabled(forIdentity: device.identityKey, enabled: enabled)
        } else {
            popoverChrome.animatingDisclosure {
                appState.setEnabled(forIdentity: device.identityKey, enabled: enabled)
            }
        }
    }

    /// Keep EQ-enabled others in the main list; only one inspected (EQ-off) pin at a time.
    private func pinInspectedOtherDevice(_ key: String) {
        unpinInactiveOtherDevices()
        pinnedOtherDeviceKeys.insert(key)
    }

    private func unpinInactiveOtherDevices() {
        pinnedOtherDeviceKeys = Set(pinnedOtherDeviceKeys.filter {
            appState.shouldListInactiveOutput($0)
        })
    }

    private func focusOtherDevice(_ device: AudioOutputDevice, animated: Bool) {
        let key = device.identityKey
        pinInspectedOtherDevice(key)
        let effects = preferredEffectsProgress(for: key)
        if animated {
            popoverChrome.animatingDisclosure {
                otherDevicesListProgress = 0
                activePanelProgress = 0
                activeOtherProfilesProgress = 0
                activeEffectsProgress = 0
                expandedOtherDeviceKey = key
                otherDevicePanelProgress = 1
                inactiveOtherProfilesProgress = preferredOtherProfilesProgress(for: key)
                inactiveEffectsProgress = effects
                colorPickerIdentityKey = nil
                if renamingIdentityKey != key {
                    endRenameIfNeeded()
                }
            }
        } else {
            otherDevicesListProgress = 0
            activePanelProgress = 0
            activeOtherProfilesProgress = 0
            activeEffectsProgress = 0
            expandedOtherDeviceKey = key
            otherDevicePanelProgress = 1
            inactiveOtherProfilesProgress = preferredOtherProfilesProgress(for: key)
            inactiveEffectsProgress = effects
            colorPickerIdentityKey = nil
            if renamingIdentityKey != key {
                endRenameIfNeeded()
            }
        }
    }

    private func focusActiveOutput(animated: Bool) {
        let activeKey = activeDevice?.identityKey
        let effects = activeKey.map { preferredEffectsProgress(for: $0) } ?? 0
        if animated {
            popoverChrome.animatingDisclosure {
                unpinInactiveOtherDevices()
                otherDevicesListProgress = 0
                activePanelProgress = 1
                activeOtherProfilesProgress = activeKey.map { preferredOtherProfilesProgress(for: $0) } ?? 1
                activeEffectsProgress = effects
                otherDevicePanelProgress = 0
                inactiveOtherProfilesProgress = 0
                inactiveEffectsProgress = 0
                colorPickerIdentityKey = nil
                if let renamingIdentityKey, renamingIdentityKey != activeKey {
                    endRenameIfNeeded()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + PopoverChrome.disclosureDuration) {
                if otherDevicePanelProgress < 0.01 {
                    expandedOtherDeviceKey = nil
                }
            }
        } else {
            unpinInactiveOtherDevices()
            otherDevicesListProgress = 0
            activePanelProgress = 1
            activeOtherProfilesProgress = activeKey.map { preferredOtherProfilesProgress(for: $0) } ?? 1
            activeEffectsProgress = effects
            expandedOtherDeviceKey = nil
            otherDevicePanelProgress = 0
            inactiveOtherProfilesProgress = 0
            inactiveEffectsProgress = 0
            colorPickerIdentityKey = nil
            if let renamingIdentityKey, renamingIdentityKey != activeKey {
                endRenameIfNeeded()
            }
        }
    }

    /// No EQ selected, or any effect on → Effects starts open.
    private func preferredEffectsProgress(for identityKey: String) -> CGFloat {
        let mapping = appState.config.mapping(forIdentity: identityKey)
        if mapping.profileFilename == nil { return 1 }
        return mapping.effects.isAudible ? 1 : 0
    }

    /// No EQ selected → Available EQs starts open so you can pick one.
    private func preferredOtherProfilesProgress(for identityKey: String) -> CGFloat {
        appState.config.mapping(forIdentity: identityKey).profileFilename == nil ? 1 : 0
    }

    private func syncRenameText() {
        renameOutsideClicksEnabled = false
        renamingIdentityKey = nil
        renameText = ""
    }

    /// Expand the row if needed, then enter rename with the name selected.
    private func requestRename(_ device: AudioOutputDevice) {
        let isActive = device.identityKey == activeDevice?.identityKey
        if isActive {
            if !isActivePanelVisible {
                focusActiveOutput(animated: false)
            }
        } else if expandedOtherDeviceKey != device.identityKey || otherDevicePanelProgress < 0.5 {
            focusOtherDevice(device, animated: false)
        }
        // Context menu steals key window on accessory apps; wait for it to finish
        // dismissing before mounting the AppKit field (which re-keys + selects all).
        DispatchQueue.main.async {
            beginRename(device)
        }
    }

    private func beginRename(_ device: AudioOutputDevice) {
        renameOutsideClicksEnabled = false
        renameSessionID &+= 1
        renamingIdentityKey = device.identityKey
        renameText = device.name
        // Ignore the context-menu click that just dismissed, then arm outside-commit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard renamingIdentityKey == device.identityKey else { return }
            renameOutsideClicksEnabled = true
        }
    }

    private func endRenameIfNeeded() {
        guard renamingIdentityKey != nil else { return }
        commitRename()
    }

    private func commitRename() {
        let key = renamingIdentityKey
        defer {
            renameOutsideClicksEnabled = false
            renamingIdentityKey = nil
            renameText = ""
        }
        guard let key else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = appState.devices.first(where: { $0.identityKey == key })?.name
            ?? (key == AppConfig.allAudioIdentityKey ? appState.allAudioDisplayName : nil)
        if trimmed != current {
            appState.setDisplayName(forIdentity: key, name: trimmed)
        }
    }
}

/// AppKit field — SwiftUI `TextField` + `FocusState` often fails to select-all after a
/// context menu on the first open (panel isn’t key again until some other interaction).
private struct DeviceRenameField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> RenameNSTextField {
        let field = RenameNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .labelColor
        field.stringValue = text
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        context.coordinator.field = field
        field.onMovedToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleFocusAndSelectAll()
        }
        context.coordinator.scheduleFocusAndSelectAll()
        return field
    }

    func updateNSView(_ field: RenameNSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.text = $text
        field.font = font
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        weak var field: RenameNSTextField?
        private var didClaimFocus = false
        private var isCommitting = false
        /// Ignores end-editing from key-window churn while we claim first responder.
        private var acceptsEndEditing = false

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        /// One focus claim when the field lands in a window; select on the next run loop.
        func scheduleFocusAndSelectAll() {
            guard !didClaimFocus else { return }
            guard let field, let window = field.window else { return }
            didClaimFocus = true

            NSApp.activate(ignoringOtherApps: true)
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            _ = window.makeFirstResponder(field)

            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field, let editor = field.currentEditor() else { return }
                let length = (editor.string as NSString).length
                editor.selectedRange = NSRange(location: 0, length: length)
                self.acceptsEndEditing = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard acceptsEndEditing else { return }
            commitOnce()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                acceptsEndEditing = true
                commitOnce()
                return true
            }
            return false
        }

        private func commitOnce() {
            guard !isCommitting else { return }
            isCommitting = true
            onCommit()
        }
    }
}

private final class RenameNSTextField: NSTextField {
    var onMovedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow?()
        }
    }

    override var intrinsicContentSize: NSSize {
        // Width comes from SwiftUI’s frame — growing with the string stretched the menu.
        NSSize(width: NSView.noIntrinsicMetric, height: MenuChrome.textRowContentHeight)
    }
}

extension Notification.Name {
    static let audiochromeDidEndTextEditing = Notification.Name("audiochromeDidEndTextEditing")
}

/// Clicking outside an editable field resigns first responder (clears caret + selection).
struct EndEditingClickMonitor: NSViewRepresentable {
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
        context.coordinator.setEnabled(true)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
        }

        func setEnabled(_ enabled: Bool) {
            if enabled {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    guard let panel = self.view?.window, event.window === panel else { return event }
                    if self.isClickInEditableField(event) { return event }
                    let responder = panel.firstResponder
                    if responder != nil, !(responder is NSWindow) {
                        panel.makeFirstResponder(nil)
                        NotificationCenter.default.post(name: .audiochromeDidEndTextEditing, object: nil)
                    }
                    return event
                }
            } else {
                teardown()
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func isClickInEditableField(_ event: NSEvent) -> Bool {
            guard let content = event.window?.contentView else { return false }
            guard let hit = content.hitTest(event.locationInWindow) else { return false }
            var current: NSView? = hit
            while let view = current {
                if let field = view as? NSTextField {
                    return field.isEditable && field.isEnabled
                }
                if view is NSTextView {
                    return true
                }
                current = view.superview
            }
            return false
        }
    }
}

/// Commits an in-progress rename when the user clicks elsewhere in the menu panel.
private struct RenameOutsideClickMonitor: NSViewRepresentable {
    var enabled: Bool
    var onOutside: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutside: onOutside)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOutside = onOutside
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        var onOutside: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onOutside: @escaping () -> Void) {
            self.onOutside = onOutside
        }

        func attach(to view: NSView) {
            self.view = view
        }

        func setEnabled(_ enabled: Bool) {
            if enabled {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    guard let panel = self.view?.window, event.window === panel else { return event }
                    if self.isClickInRenameField(event) { return event }
                    DispatchQueue.main.async { self.onOutside() }
                    return event
                }
            } else {
                teardown()
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func isClickInRenameField(_ event: NSEvent) -> Bool {
            guard let content = event.window?.contentView else { return false }
            guard let hit = content.hitTest(event.locationInWindow) else { return false }
            var current: NSView? = hit
            while let view = current {
                if view is NSTextField || view is NSTextView { return true }
                current = view.superview
            }
            return false
        }
    }
}

private struct HomeScrollableHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Wi‑Fi / Control Center chrome metrics

enum MenuChrome {
    static let contentInset: CGFloat = 16
    static let dividerInset: CGFloat = 16
    static let menuPadding: CGFloat = 10
    static let headerVerticalPadding: CGFloat = 10
    static let sectionTopPadding: CGFloat = 8
    static let sectionToContentSpacing: CGFloat = 6
    static let waveformSpacing: CGFloat = 6
    static let waveformBottomPadding: CGFloat = 2
    static let otherProfilesSectionVerticalPadding: CGFloat = 6
    /// Wordmark height in the break above Settings (asset is ~5.4∶1).
    static let logoHeight: CGFloat = 18
    static let logoBreakBottomPadding: CGFloat = 9
    static let logoBreakTopPadding: CGFloat = 28
    /// Dimmed chrome below the audio-permission CTA.
    static let permissionLockedOpacity: Double = 0.4

    static let headerFontSize: CGFloat = 13
    static let bodyFontSize: CGFloat = 13
    /// Sub-header (“Active EQ”) and expanding headers (“EQs”).
    static let sectionFontSize: CGFloat = 12
    static let headerWeight: Font.Weight = .bold
    static let sectionWeight: Font.Weight = .bold
    /// Regular — medium still read as bold next to Apple’s list rows.
    static let bodyWeight: Font.Weight = .regular

    static var headerFont: Font { .system(size: headerFontSize, weight: headerWeight) }
    static var sectionFont: Font { .system(size: sectionFontSize, weight: sectionWeight) }
    /// Bridged through AppKit so macOS `Button` chrome can’t promote the weight.
    static var bodyFont: Font {
        Font(NSFont.systemFont(ofSize: bodyFontSize, weight: .regular))
    }
    static var mediumFont: Font {
        Font(NSFont.systemFont(ofSize: bodyFontSize, weight: .medium))
    }

    static let textRowContentHeight: CGFloat = 20
    static let textRowHeight: CGFloat = 28
    static let iconRowHeight: CGFloat = 34
    static let sectionRowHeight: CGFloat = 24

    /// Toggle marks (EQ profiles, effects). Menu-bar status item stays 18.
    static let listIconSize: CGFloat = 26
    /// Command / action glyphs (Create New EQ, Export, Change Folder).
    static let commandIconSize: CGFloat = 16
    /// Selected profile / effect while the device toggle is off.
    static let pausedMarkPlate = Color(nsColor: .systemGray)
    static let pausedMarkInk = Color.white
    static let chevronSize: CGFloat = 10
    /// Intrinsic width of a regular `NSSwitch` (filter toggles, Save chip).
    static let switchWidth: CGFloat = {
        let control = NSSwitch()
        control.controlSize = .regular
        let width = control.intrinsicContentSize.width
        return width > 0 ? width : 54
    }()
    /// Plot height; dB scale maps to this full height (2pt stroke inset).
    static let waveformHeight: CGFloat = 128

    static var highlightInset: CGFloat {
        if #available(macOS 26, *) { return 8 }
        return 5
    }

    static var highlightCornerRadius: CGFloat {
        if #available(macOS 26, *) { return 10 }
        return 5
    }

    /// Full-bleed nested-section fill (Focus “For 1 hour” band). Darker in light mode,
    /// lighter in dark mode, so it reads on glass / vibrancy.
    static let groupedFill = Color.primary.opacity(0.06)
}

/// Edge-to-edge dimmer behind rows that belong to the heading above.
struct MenuGroupedSection<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(MenuChrome.groupedFill)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - EQ panel (identical for active + inactive outputs)

private enum UnlistedDevicesMetrics {
    /// Match Available Profiles list rows (`iconRowHeight`), not footer command rows.
    static let rowHeight: CGFloat = MenuChrome.iconRowHeight
    static let rowSpacing: CGFloat = OutputEQPanelMetrics.disclosureRowSpacing
    static let maxVisibleRows = 7

    static func scrollHeight(count: Int) -> CGFloat {
        let visible = min(max(0, count), maxVisibleRows)
        guard visible > 0 else { return 0 }
        return CGFloat(visible) * rowHeight + CGFloat(max(0, visible - 1)) * rowSpacing
    }

    static func bodyHeight(count: Int) -> CGFloat {
        scrollHeight(count: count)
    }
}

private enum OutputEQPanelMetrics {
    static let disclosureRowHeight: CGFloat = MenuChrome.sectionRowHeight
    static let iconRowHeight: CGFloat = MenuChrome.iconRowHeight
    static let textRowHeight: CGFloat = MenuChrome.textRowHeight
    static let disclosureRowSpacing: CGFloat = 2
    /// Cap so a long folder doesn’t shove Change Folder / other outputs / Quit off-screen.
    static let maxVisibleOtherProfileRows = 7

    /// “Active EQ” header + row + waveform (flat when no EQ is on).
    static func activeProfileBlockHeight() -> CGFloat {
        MenuChrome.sectionTopPadding
            + MenuChrome.sectionRowHeight
            + iconRowHeight
            + MenuChrome.waveformSpacing
            + MenuChrome.waveformHeight
            + MenuChrome.waveformSpacing
    }

    /// Permission slot: Active EQ header + message row + settings pill.
    /// Keep in lockstep with `audioPermissionPlaceholder` paddings.
    static func audioPermissionBlockHeight() -> CGFloat {
        MenuChrome.sectionTopPadding
            + MenuChrome.sectionRowHeight
            + iconRowHeight
            + MenuChrome.waveformSpacing
            + iconRowHeight
            + MenuChrome.waveformBottomPadding
    }

    static func otherProfilesListHeight(count: Int) -> CGFloat {
        let c = CGFloat(max(0, count))
        guard c > 0 else { return 0 }
        return c * iconRowHeight + max(0, c - 1) * disclosureRowSpacing
    }

    /// Scrollable profile rows only (Change Folder sits sticky beneath).
    static func otherProfilesScrollHeight(profileCount: Int) -> CGFloat {
        otherProfilesListHeight(count: min(profileCount, maxVisibleOtherProfileRows))
    }

    /// Expanded disclosure body: scrolling profiles + sticky Change Folder.
    static func otherProfilesExpandedBodyHeight(profileCount: Int) -> CGFloat {
        let scroll = otherProfilesScrollHeight(profileCount: profileCount)
        // Change Folder uses `.command` → iconRowHeight (same as profile rows).
        return scroll <= 0
            ? iconRowHeight
            : scroll + disclosureRowSpacing + iconRowHeight
    }

    @MainActor
    static func height(
        appState: AppState,
        identityKey: String,
        otherProfilesProgress: CGFloat,
        effectsProgress: CGFloat,
        showsLeadingDivider: Bool
    ) -> CGFloat {
        let profiles = appState.profiles(forIdentity: identityKey)

        var height: CGFloat = 0
        if showsLeadingDivider {
            height += 1 // Divider visual weight (padded elsewhere; keep tiny)
        }

        if appState.needsAudioPermission,
           identityKey == appState.activeMappingIdentityKey {
            height += audioPermissionBlockHeight()
        } else {
            height += activeProfileBlockHeight()
        }

        height += MenuChrome.otherProfilesSectionVerticalPadding
        height += iconRowHeight // Create New EQ
        height += MenuChrome.otherProfilesSectionVerticalPadding
        height += disclosureRowHeight // Available EQs header
        height += otherProfilesProgress * otherProfilesExpandedBodyHeight(profileCount: profiles.count)
        if !DeviceEffects.listedKinds.isEmpty {
            height += MenuChrome.otherProfilesSectionVerticalPadding
            height += 1 // divider before Effects
        }
        height += EffectsSectionMetrics.height(progress: effectsProgress)
        return height
    }
}

private struct OutputEQPanel: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @Environment(\.colorScheme) private var colorScheme
    let identityKey: String
    @Binding var otherProfilesProgress: CGFloat
    @Binding var effectsProgress: CGFloat
    @Binding var colorPickerIdentityKey: String?
    var showsLeadingDivider: Bool = true
    /// A/B Compare only on the default output — inactive device panels can’t drive live EQ.
    var showsCompare: Bool = true
    @State private var isProfileDropTargeted = false

    private var mapping: OutputMapping {
        appState.config.mapping(forIdentity: identityKey)
    }

    private var profiles: [ProfileFile] {
        appState.profiles(forIdentity: identityKey)
    }

    private var hasProfile: Bool {
        mapping.profileFilename != nil
    }

    private var profileTitle: String {
        guard let filename = mapping.profileFilename else { return "None" }
        if let profile = profiles.first(where: { $0.filename == filename }) {
            return profile.displayName
        }
        return (filename as NSString).deletingPathExtension
    }

    private var accent: Color {
        guard let filename = mapping.profileFilename else {
            return Color(nsColor: .systemGray)
        }
        return appState.colorHex(forProfile: filename, forIdentity: identityKey)
            .profileColor(.ui, scheme: colorScheme)
    }

    private var showColorPicker: Binding<Bool> {
        Binding(
            get: { colorPickerIdentityKey == identityKey },
            set: { colorPickerIdentityKey = $0 ? identityKey : nil }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLeadingDivider {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
            }

            activeProfileSection

            PlusCommandRow(title: "Create new EQ", action: openCreateEditor)
                .padding(.top, MenuChrome.otherProfilesSectionVerticalPadding)
                .padding(.bottom, MenuChrome.otherProfilesSectionVerticalPadding)
                .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
                .disabled(appState.needsAudioPermission)

            otherProfilesSection
                .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
                .disabled(appState.needsAudioPermission)

            if !DeviceEffects.listedKinds.isEmpty {
                Divider()
                    .padding(.horizontal, MenuChrome.dividerInset)
                    .padding(.top, MenuChrome.otherProfilesSectionVerticalPadding)

                EffectsSection(identityKey: identityKey, progress: $effectsProgress)
                    .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
                    .disabled(appState.needsAudioPermission)
            }
        }
        .onAppear {
            if mapping.effects.isAudible || !hasProfile {
                effectsProgress = 1
            }
            if !hasProfile {
                otherProfilesProgress = 1
            }
        }
        .onChange(of: mapping.effects) { _, effects in
            guard effects.isAudible, effectsProgress < 0.5 else { return }
            popoverChrome.animatingDisclosure {
                effectsProgress = 1
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(isProfileDropTargeted ? 0.12 : 0))
                .padding(.horizontal, 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(isProfileDropTargeted ? 0.85 : 0), lineWidth: 1.5)
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let imported = appState.importAndActivateProfiles(from: urls, forIdentity: identityKey)
            return imported
        } isTargeted: { targeted in
            isProfileDropTargeted = targeted
        }
    }

    private var activeProfileSection: some View {
        Group {
            if appState.needsAudioPermission, showsCompare {
                audioPermissionPlaceholder
                    .frame(
                        height: OutputEQPanelMetrics.audioPermissionBlockHeight(),
                        alignment: .top
                    )
            } else {
                let blockHeight = OutputEQPanelMetrics.activeProfileBlockHeight()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Active EQ")
                        .font(MenuChrome.sectionFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                        .padding(.horizontal, MenuChrome.contentInset)
                        .padding(.top, MenuChrome.sectionTopPadding)

                    ActiveProfileRow(
                        title: profileTitle,
                        accent: accent,
                        colorHex: mapping.profileFilename.map {
                            appState.colorHex(forProfile: $0, forIdentity: identityKey)
                        },
                        hasProfile: hasProfile,
                        isPaused: hasProfile && !mapping.enabled,
                        showColorPicker: showColorPicker,
                        colorPicker: { colorPopover },
                        onEdit: hasProfile ? { openEditEditor() } : nil
                    ) {
                        guard hasProfile else { return }
                        popoverChrome.animatingDisclosure {
                            appState.setProfile(forIdentity: identityKey, filename: nil)
                            otherProfilesProgress = 1
                            effectsProgress = 1
                        }
                    }

                    ZStack(alignment: .topTrailing) {
                        let eqLive = hasProfile && mapping.enabled
                        ProfileWaveformView(
                            preview: eqLive
                                ? appState.eqFrequencyResponse(forIdentity: identityKey)
                                : nil,
                            colorHex: mapping.profileFilename.map {
                                appState.colorHex(forProfile: $0, forIdentity: identityKey)
                            } ?? mapping.colorHex,
                            isPaused: hasProfile && !mapping.enabled,
                            isNeutral: !eqLive
                        )
                        .frame(height: MenuChrome.waveformHeight)

                        if eqLive, showsCompare {
                            CompareChip(isOn: appState.isEQComparing) { comparing in
                                appState.setEQComparing(comparing)
                            }
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                        }
                    }
                    .padding(.horizontal, MenuChrome.contentInset)
                    .padding(.top, MenuChrome.waveformSpacing)
                    .padding(.bottom, MenuChrome.waveformSpacing)
                }
                .frame(height: blockHeight, alignment: .top)
            }
        }
    }

    /// Active EQ header + status line + Privacy & Security pill.
    private var audioPermissionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Active EQ")
                .font(MenuChrome.sectionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.sectionTopPadding)

            Text("System audio access required to process audio")
                .font(MenuChrome.bodyFont)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)
                .frame(height: MenuChrome.iconRowHeight, alignment: .leading)

            PermissionActionPillButton(title: "Privacy & Security settings", showsExternalLink: true) {
                appState.openAudioPermissionSettings()
            }
            .padding(.horizontal, MenuChrome.highlightInset)
            .padding(.top, MenuChrome.waveformSpacing)
            .padding(.bottom, MenuChrome.waveformBottomPadding)
        }
    }

    private var otherProfilesSection: some View {
        let profileCount = profiles.count
        let scrollHeight = OutputEQPanelMetrics.otherProfilesScrollHeight(profileCount: profileCount)
        let bodyHeight = OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: profileCount)
        let needsScroll = profileCount > OutputEQPanelMetrics.maxVisibleOtherProfileRows

        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: "Available EQs",
                subtitle: profiles.count == 1 ? "1 profile" : "\(profiles.count) profiles",
                style: .disclosure,
                trailing: otherProfilesProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let target: CGFloat = otherProfilesProgress < 0.5 ? 1 : 0
                popoverChrome.animatingDisclosure {
                    otherProfilesProgress = target
                }
            }

            VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                if scrollHeight > 0 {
                    ScrollViewport(showsIndicators: needsScroll) {
                        VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                            ForEach(profiles) { profile in
                                OtherProfileRow(
                                    profile: profile,
                                    colorHex: appState.colorHex(
                                        forProfile: profile.filename,
                                        forIdentity: identityKey
                                    ),
                                    isSelected: profile.filename == mapping.profileFilename,
                                    isPaused: profile.filename == mapping.profileFilename && !mapping.enabled
                                ) {
                        popoverChrome.animatingDisclosure {
                            let filename = profile.filename == mapping.profileFilename
                                ? nil
                                : profile.filename
                            appState.setProfile(forIdentity: identityKey, filename: filename)
                            if filename == nil {
                                otherProfilesProgress = 1
                                effectsProgress = 1
                            }
                        }
                    } onDelete: {
                                    popoverChrome.animatingDisclosure {
                                        let wasSelected = profile.filename == mapping.profileFilename
                                        appState.deleteProfile(profile, forIdentity: identityKey)
                                        if wasSelected {
                                            otherProfilesProgress = 1
                                            effectsProgress = 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: scrollHeight, alignment: .top)
                    .scrollBounceBehavior(.basedOnSize)
                }

                // Sticky under the scrolling list (Wi‑Fi–style).
                ControlCenterRow(title: "Change folder…", style: .command, leading: .folder) {
                    appState.chooseProfilesFolder(forIdentity: identityKey)
                }
            }
            .frame(height: otherProfilesProgress * bodyHeight, alignment: .top)
            .clipped()
            .opacity(otherProfilesProgress)
            .allowsHitTesting(otherProfilesProgress > 0.98)
        }
    }

    private var colorPopover: some View {
        let activeFilename = mapping.profileFilename
        let selectedHex = activeFilename.map {
            appState.colorHex(forProfile: $0, forIdentity: identityKey)
        } ?? mapping.colorHex
        return HStack(spacing: 10) {
            ForEach(ProfileColorPalette.swatches, id: \.self) { hex in
                Circle()
                    .fill(hex.asHexColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if ProfileColorPalette.canonical(selectedHex) == hex {
                            Circle().strokeBorder(.primary, lineWidth: 1.5)
                        }
                    }
                    .onTapGesture {
                        if let activeFilename {
                            appState.setProfileColor(filename: activeFilename, hex: hex)
                        } else {
                            appState.setColor(forIdentity: identityKey, hex: hex)
                        }
                        colorPickerIdentityKey = nil
                    }
            }
        }
        .padding(10)
    }

    private func openCreateEditor() {
        appState.beginCreateProfile(forIdentity: identityKey)
        popoverChrome.present(.eqEditor)
    }

    private func openEditEditor() {
        guard let filename = mapping.profileFilename else { return }
        appState.beginEditProfile(forIdentity: identityKey, filename: filename)
        popoverChrome.present(.eqEditor)
    }
}

/// A/B compare chip — matches `ValuePill` size/type. Click toggles; hold previews dry until release.
struct CompareChip: View {
    var isOn: Bool
    var subject: String = "EQ"
    var setComparing: (Bool) -> Void

    @State private var pressStartedAt: Date?
    @State private var wasOnAtPress = false

    private static let holdThreshold: TimeInterval = 0.18

    var body: some View {
        Text("Compare")
            .font(MenuChrome.bodyFont)
            .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: ValuePill.height)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isOn ? 0.10 : 0))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(isOn ? 0 : 0.10), lineWidth: 1)
                    }
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressStartedAt == nil else { return }
                        wasOnAtPress = isOn
                        pressStartedAt = Date()
                        if !isOn {
                            setComparing(true)
                        }
                    }
                    .onEnded { _ in
                        let started = pressStartedAt ?? Date()
                        pressStartedAt = nil
                        let held = Date().timeIntervalSince(started) >= Self.holdThreshold
                        if held {
                            setComparing(false)
                        } else {
                            setComparing(!wasOnAtPress)
                        }
                    }
            )
            .accessibilityLabel("Compare \(subject)")
            .accessibilityHint("Toggle bypass. Press and hold to preview, then release.")
            .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
    }
}

// MARK: - EQ frequency-response curve

struct ProfileWaveformView: View {
    let preview: EQFrequencyResponsePreview?
    let colorHex: String
    /// Home panel only — device toggle off. Editor stays in profile color.
    var isPaused: Bool = false
    /// Home: no profile or EQ off. Same paint as a live curve, in grayscale.
    var isNeutral: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        if isNeutral { return MenuChrome.pausedMarkPlate }
        return isPaused ? MenuChrome.pausedMarkPlate : colorHex.profileColor(.curve, scheme: colorScheme)
    }

    private static let verticalInset: CGFloat = 2
    private static let strokeWidth: CGFloat = 1.25
    private static let halfRangeDB: Double = EQProfile.waveformRangeDB / 2
    private static let underCurveTopOpacity: Double = 0.32
    private static let curveBlackOverlayOpacity: Double = 0.20
    private static let freqMinHz: Double = 20
    private static let freqMaxHz: Double = 20_000
    private static let gridLineWidth: CGFloat = 1
    private static let gridOpacity: Double = 0.22

    var body: some View {
        Canvas { context, size in
            // Curve runs edge-to-edge in the container (no horizontal plot inset).
            let plot = CGRect(
                x: 0,
                y: Self.verticalInset,
                width: max(0, size.width),
                height: max(0, size.height - Self.verticalInset * 2)
            )
            let style = StrokeStyle(
                lineWidth: Self.strokeWidth,
                lineCap: .butt,
                lineJoin: .round
            )

            let path: Path
            if let preview, preview.magnitudesDB.count >= 2 {
                path = Self.curvePath(magnitudesDB: preview.magnitudesDB, plot: plot)
            } else {
                var flat = Path()
                let y = plot.midY
                flat.move(to: CGPoint(x: plot.minX, y: y))
                flat.addLine(to: CGPoint(x: plot.maxX, y: y))
                path = flat
            }

            var fill = path
            fill.addLine(to: CGPoint(x: plot.maxX, y: size.height))
            fill.addLine(to: CGPoint(x: plot.minX, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [
                        color.opacity(Self.underCurveTopOpacity),
                        color.opacity(0),
                    ]),
                    startPoint: CGPoint(x: plot.midX, y: plot.minY),
                    endPoint: CGPoint(x: plot.midX, y: size.height)
                )
            )

            Self.strokeGrid(&context, plot: plot, color: color)

            context.stroke(path, with: .color(color), style: style)
            context.stroke(path, with: .color(Color.black.opacity(Self.curveBlackOverlayOpacity)), style: style)
        }
        .background {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous))
        // Glass re-blends translucent pixels live; bake so the fade + line stay as authored.
        .drawingGroup()
        .accessibilityLabel("EQ frequency response")
    }

    private static func curvePath(magnitudesDB: [Double], plot: CGRect) -> Path {
        let half = halfRangeDB
        let minDB = magnitudesDB.min() ?? 0
        let maxDB = magnitudesDB.max() ?? 0
        let center = (minDB + maxDB) / 2
        let lo = center - half
        let hi = center + half
        let span = max(hi - lo, 1)

        var path = Path()
        let last = magnitudesDB.count - 1
        for (i, db) in magnitudesDB.enumerated() {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(last)
            let t = min(1, max(0, (db - lo) / span))
            let y = plot.minY + plot.height * (1 - CGFloat(t))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// Vertical log-frequency ticks: 1…9 × 10ⁿ Hz, matching a 20 Hz–20 kHz audio chart.
    private static func strokeGrid(_ context: inout GraphicsContext, plot: CGRect, color: Color) {
        let style = StrokeStyle(lineWidth: gridLineWidth, lineCap: .butt)
        let logSpan = log(freqMaxHz / freqMinHz)
        let edge: CGFloat = 0.75
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                color.opacity(0),
                color.opacity(gridOpacity),
            ]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        )

        var decade = 10.0
        while decade < freqMaxHz * 10 {
            for multiplier in 1...9 {
                let hz = Double(multiplier) * decade
                guard hz > freqMinHz, hz < freqMaxHz else { continue }
                let t = log(hz / freqMinHz) / logSpan
                let x = plot.minX + plot.width * CGFloat(t)
                guard x > plot.minX + edge, x < plot.maxX - edge else { continue }
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: shading, style: style)
            }
            decade *= 10
        }
    }
}

/// Filled pill matching command-row height; text lines up with body labels.
private struct PermissionActionPillButton: View {
    let title: String
    var showsExternalLink: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    /// Keep label flush with `contentInset` while the fill uses `highlightInset`.
    private var labelInset: CGFloat {
        max(0, MenuChrome.contentInset - MenuChrome.highlightInset)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(MenuChrome.bodyFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsExternalLink {
                    ExternalLinkIcon()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, labelInset)
            .frame(height: MenuChrome.iconRowHeight)
            .background {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.14 : 0.10))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Control Center rows

enum ControlCenterTrailing {
    case none
    case chevronRight
    case chevronDown
    case externalLink
}

enum ControlCenterLeading {
    case none
    case folder
    case fileExport
    case fileImport
    case restore
    case externalLink
}

enum ControlCenterRowStyle {
    /// Footer / Change Folder — same height as profile & Other Devices rows.
    case command
    /// Other Devices list rows — same height as Available Profiles items.
    case listItem
    /// “Available Profiles” / “Other Devices” — 12 bold secondary + chevron.
    case disclosure
}

private struct ActiveProfileRow<ColorPicker: View>: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let accent: Color
    var colorHex: String? = nil
    let hasProfile: Bool
    var isPaused: Bool = false
    @Binding var showColorPicker: Bool
    @ViewBuilder let colorPicker: () -> ColorPicker
    var onEdit: (() -> Void)? = nil
    let onDeselect: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(isHovering && hasProfile ? Color.primary.opacity(0.10) : Color.clear)
                .padding(.horizontal, MenuChrome.highlightInset)

            HStack(spacing: 10) {
                Button {
                    guard hasProfile else { return }
                    showColorPicker = true
                } label: {
                    ProfileMarkView(
                        colorHex: colorHex,
                        isSelected: hasProfile,
                        showsBars: hasProfile,
                        isPaused: isPaused
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasProfile)
                .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                    colorPicker()
                }

                Text(title)
                    .font(MenuChrome.bodyFont)
                    .fontWeight(.regular)
                    .foregroundStyle(hasProfile ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard hasProfile else { return }
                        onDeselect()
                    }

                if hasProfile, let onEdit {
                    EditSettingsButton(action: onEdit)
                }
            }
            .padding(.horizontal, MenuChrome.contentInset)
        }
        .frame(height: MenuChrome.iconRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering && hasProfile
        }
        .focusEffectDisabled()
    }
}

private struct OtherProfileRow: View {
    let title: String
    let colorHex: String
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var isPaused: Bool = false
    let action: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false

    init(
        profile: ProfileFile,
        colorHex: String,
        isSelected: Bool = false,
        isPaused: Bool = false,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = profile.displayName
        self.colorHex = colorHex
        self.isEnabled = true
        self.isSelected = isSelected
        self.isPaused = isPaused
        self.action = action
        self.onDelete = onDelete
    }

    init(
        title: String,
        colorHex: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.colorHex = colorHex
        self.isEnabled = isEnabled
        self.action = action
        self.onDelete = onDelete
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, MenuChrome.highlightInset)

                HStack(spacing: 10) {
                    ProfileMarkView(
                        colorHex: colorHex,
                        isSelected: isSelected,
                        isPaused: isPaused,
                        showsOnPlate: isSelected
                    )
                    Text(title)
                        .font(MenuChrome.bodyFont)
                        .fontWeight(.regular)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, MenuChrome.contentInset)
            }
            .frame(height: MenuChrome.iconRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(MenuChrome.bodyFont)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onDelete {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

struct ControlCenterRow: View {
    let title: String
    var subtitle: String? = nil
    var style: ControlCenterRowStyle = .command
    var leading: ControlCenterLeading = .none
    var trailing: ControlCenterTrailing = .none
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    private var isInteractive: Bool { action != nil }

    private var rowHeight: CGFloat {
        switch style {
        case .command, .listItem: return MenuChrome.iconRowHeight
        case .disclosure: return MenuChrome.sectionRowHeight
        }
    }

    private var titleFont: Font {
        switch style {
        case .command, .listItem:
            return MenuChrome.bodyFont
        case .disclosure:
            return MenuChrome.sectionFont
        }
    }

    private var titleColor: Color {
        switch style {
        case .command, .listItem:
            return isInteractive ? .primary : .secondary
        case .disclosure: return .secondary
        }
    }

    var body: some View {
        let label = ZStack {
            RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                .fill(isHovering && isInteractive ? Color.primary.opacity(0.10) : Color.clear)
                .padding(.horizontal, MenuChrome.highlightInset)

            HStack(spacing: leading == .none ? 0 : 10) {
                switch leading {
                case .none:
                    EmptyView()
                case .folder:
                    FolderOpenIcon()
                        .foregroundStyle(.primary)
                case .fileExport:
                    FileExportIcon()
                        .foregroundStyle(.primary)
                case .fileImport:
                    FileImportIcon()
                        .foregroundStyle(.primary)
                case .restore:
                    RestoreIcon()
                        .foregroundStyle(.primary)
                case .externalLink:
                    // 17×17 art is full-bleed; 16pt reads larger than the plus/folder glyphs.
                    ExternalLinkIcon(size: 12)
                        .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
                        .foregroundStyle(.primary)
                }

                Text(title)
                    .font(titleFont)
                    .fontWeight(style == .disclosure ? .bold : .regular)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.trailing, 6)
                }

                switch trailing {
                case .none:
                    EmptyView()
                case .chevronRight, .chevronDown:
                    // Slot is the wider glyph so a subtitle 6pt away doesn’t shift.
                    ZStack(alignment: .trailing) {
                        chevronImage("chevron.down").hidden()
                        chevronImage("chevron.right").hidden()
                        chevronImage(trailing == .chevronDown ? "chevron.down" : "chevron.right")
                    }
                case .externalLink:
                    ExternalLinkIcon()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, MenuChrome.contentInset)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())

        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
            } else {
                label
            }
        }
        .font(titleFont)
        .focusEffectDisabled()
    }

    private func chevronImage(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: MenuChrome.chevronSize, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

struct PlusCommandRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, MenuChrome.highlightInset)

                HStack(spacing: 10) {
                    PlusCircleIcon()
                        .foregroundStyle(.primary)
                    Text(title)
                        .font(MenuChrome.bodyFont)
                        .fontWeight(.regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, MenuChrome.contentInset)
            }
            .frame(height: MenuChrome.iconRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(MenuChrome.bodyFont)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

/// Tabler `folder-open` (24×24), drawn at command-icon size.
private struct FolderOpenIcon: View {
    var body: some View {
        FolderOpenShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.commandIconSize, height: MenuChrome.commandIconSize)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
    }
}

private struct FolderOpenShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(5, 19))
        path.addLine(to: pt(7.757, 11.649))
        path.addQuadCurve(to: pt(8.693, 11), control: pt(8.693, 11.649))
        path.addLine(to: pt(21, 11))
        path.addQuadCurve(to: pt(21.986, 12.164), control: pt(21.986, 11))
        path.addLine(to: pt(20.99, 17.375))
        path.addQuadCurve(to: pt(19.026, 19), control: pt(20.99, 19))
        path.addLine(to: pt(5, 19))
        path.addQuadCurve(to: pt(3, 17), control: pt(3, 19))
        path.addLine(to: pt(3, 6))
        path.addQuadCurve(to: pt(5, 4), control: pt(3, 4))
        path.addLine(to: pt(9, 4))
        path.addLine(to: pt(12, 7))
        path.addLine(to: pt(19, 7))
        path.addQuadCurve(to: pt(21, 9), control: pt(21, 7))
        path.addLine(to: pt(21, 11))
        return path
    }
}

/// Tabler `fold-down` (24×24), drawn at command-icon size.
private struct FileExportIcon: View {
    var body: some View {
        FileExportShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.commandIconSize, height: MenuChrome.commandIconSize)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
    }
}

private struct FileExportShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(12, 11))
        path.addLine(to: pt(12, 19))
        path.addLine(to: pt(15, 16))
        path.move(to: pt(9, 16))
        path.addLine(to: pt(12, 19))

        path.move(to: pt(9, 7))
        path.addLine(to: pt(10, 7))
        path.move(to: pt(14, 7))
        path.addLine(to: pt(15, 7))
        path.move(to: pt(19, 7))
        path.addLine(to: pt(20, 7))
        path.move(to: pt(4, 7))
        path.addLine(to: pt(5, 7))
        return path
    }
}

/// Tabler `fold-up` (24×24), drawn at command-icon size.
private struct FileImportIcon: View {
    var body: some View {
        FileImportShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.commandIconSize, height: MenuChrome.commandIconSize)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
    }
}

private struct FileImportShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(12, 13))
        path.addLine(to: pt(12, 5))
        path.addLine(to: pt(9, 8))
        path.move(to: pt(15, 8))
        path.addLine(to: pt(12, 5))

        path.move(to: pt(9, 17))
        path.addLine(to: pt(10, 17))
        path.move(to: pt(14, 17))
        path.addLine(to: pt(15, 17))
        path.move(to: pt(19, 17))
        path.addLine(to: pt(20, 17))
        path.move(to: pt(4, 17))
        path.addLine(to: pt(5, 17))
        return path
    }
}

/// Tabler `restore` (24×24), drawn at command-icon size.
private struct RestoreIcon: View {
    var body: some View {
        RestoreShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.commandIconSize, height: MenuChrome.commandIconSize)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
    }
}

private struct RestoreShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        let center = pt(12, 12)
        let radius = 9 * min(sx, sy)
        func angle(to point: CGPoint) -> Angle {
            Angle(radians: atan2(point.y - center.y, point.x - center.x))
        }

        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: angle(to: pt(3.06, 13)),
            endAngle: angle(to: pt(3.55, 8.913)),
            clockwise: true
        )

        path.move(to: pt(3, 4.001))
        path.addLine(to: pt(3, 9.001))
        path.addLine(to: pt(8, 9.001))

        let dot = 1 * min(sx, sy)
        path.addEllipse(in: CGRect(
            x: center.x - dot,
            y: center.y - dot,
            width: dot * 2,
            height: dot * 2
        ))
        return path
    }
}

/// Plus-in-circle from the 37×37 create-profile SVG, drawn at command-icon size.
private struct PlusCircleIcon: View {
    var body: some View {
        PlusCircleShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.commandIconSize, height: MenuChrome.commandIconSize)
            .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
    }
}

private struct PlusCircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 37
        let sy = rect.height / 37
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        let center = pt(18.5, 18.5)
        let radius = 18 * min(sx, sy)
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        path.move(to: pt(12.5, 18.5))
        path.addLine(to: pt(24.5, 18.5))
        path.move(to: pt(18.5, 12.5))
        path.addLine(to: pt(18.5, 24.5))
        return path
    }
}

/// Trailing edit affordance — Tabler filled pencil.
struct EditSettingsButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            EditIcon()
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit")
    }
}

/// Tabler filled `pencil` (24×24).
struct EditIcon: View {
    var body: some View {
        EditIconShape()
            .fill()
            .foregroundStyle(.primary)
            .frame(width: 16, height: 16)
    }
}

private struct EditIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        var x: CGFloat = 12.085
        var y: CGFloat = 6.5
        path.move(to: map(x, y))

        func line(_ nx: CGFloat, _ ny: CGFloat) {
            x = nx
            y = ny
            path.addLine(to: map(x, y))
        }
        func relLine(_ dx: CGFloat, _ dy: CGFloat) {
            line(x + dx, y + dy)
        }
        func relArc(radius: CGFloat, large: Bool, sweep: Bool, dx: CGFloat, dy: CGFloat) {
            let x2 = x + dx
            let y2 = y + dy
            Self.addCircularArc(
                &path,
                from: map(x, y),
                to: map(x2, y2),
                radius: radius * min(sx, sy),
                largeArc: large,
                sweep: sweep
            )
            x = x2
            y = y2
        }

        relLine(5.415, 5.415)
        relLine(-8.793, 8.792)
        relArc(radius: 1, large: false, sweep: true, dx: -0.707, dy: 0.293)
        relLine(-4, 0)
        relArc(radius: 1, large: false, sweep: true, dx: -1, dy: -1)
        relLine(0, -4)
        relArc(radius: 1, large: false, sweep: true, dx: 0.293, dy: -0.707)
        path.closeSubpath()

        x = 12.085 + 5.406
        y = 6.5 - 2.698
        path.move(to: map(x, y))
        relArc(radius: 3.828, large: false, sweep: true, dx: 1.716, dy: 6.405)
        relLine(-0.292, 0.293)
        relLine(-5.415, -5.415)
        relLine(0.293, -0.292)
        relArc(radius: 3.83, large: false, sweep: true, dx: 3.698, dy: -0.991)
        return path
    }

    private static func addCircularArc(
        _ path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        radius: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0.0001 else { return }
        let radius = max(radius, distance / 2 + 0.0001)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let rise = sqrt(max(0, radius * radius - (distance / 2) * (distance / 2)))
        let direction: CGFloat = largeArc == sweep ? -1 : 1
        let center = CGPoint(
            x: mid.x + (-dy / distance) * rise * direction,
            y: mid.y + (dx / distance) * rise * direction
        )
        path.addArc(
            center: center,
            radius: radius,
            startAngle: Angle(radians: atan2(start.y - center.y, start.x - center.x)),
            endAngle: Angle(radians: atan2(end.y - center.y, end.x - center.x)),
            clockwise: !sweep
        )
    }
}

/// Matches the provided 17×17 external-link SVG (box + arrow).
struct ExternalLinkIcon: View {
    var size: CGFloat = MenuChrome.chevronSize

    var body: some View {
        ExternalLinkShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct ExternalLinkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 17
        let sy = rect.height / 17
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        // Open rounded rect (missing top-right where the arrow sits).
        path.move(to: pt(8.5, 2.5))
        path.addLine(to: pt(2.5, 2.5))
        path.addCurve(to: pt(1.08579, 3.08579), control1: pt(1.96957, 2.5), control2: pt(1.46086, 2.71071))
        path.addCurve(to: pt(0.5, 4.5), control1: pt(0.710714, 3.46086), control2: pt(0.5, 3.96957))
        path.addLine(to: pt(0.5, 14.5))
        path.addCurve(to: pt(1.08579, 15.9142), control1: pt(0.5, 15.0304), control2: pt(0.710714, 15.5391))
        path.addCurve(to: pt(2.5, 16.5), control1: pt(1.46086, 16.2893), control2: pt(1.96957, 16.5))
        path.addLine(to: pt(12.5, 16.5))
        path.addCurve(to: pt(13.9142, 15.9142), control1: pt(13.0304, 16.5), control2: pt(13.5391, 16.2893))
        path.addCurve(to: pt(14.5, 14.5), control1: pt(14.2893, 15.5391), control2: pt(14.5, 15.0304))
        path.addLine(to: pt(14.5, 8.5))

        // Arrow diagonal + corner.
        path.move(to: pt(7.5, 9.5))
        path.addLine(to: pt(16.5, 0.5))
        path.move(to: pt(11.5, 0.5))
        path.addLine(to: pt(16.5, 0.5))
        path.addLine(to: pt(16.5, 5.5))
        return path
    }
}
