import AudiochromeCore
import AppKit
import SwiftUI

/// Menu hierarchy mirrors Control Center Wi‑Fi:
/// active output + toggle → EQ panel → other outputs (same EQ panel when expanded) → footer.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    @FocusState private var focusedRenameID: Bool

    /// 1 = system-default output’s EQ panel visible; 0 = collapsed (an inactive output is focused).
    @State private var activePanelProgress: CGFloat = 1
    @State private var activeOtherProfilesProgress: CGFloat = 0

    /// Which inactive output’s EQ panel is open (`nil` = none).
    @State private var expandedOtherDeviceKey: String?
    @State private var otherDevicePanelProgress: CGFloat = 0
    @State private var inactiveOtherProfilesProgress: CGFloat = 0

    /// Inactive outputs visible for this popover session. Cleared profiles stay listed
    /// until the menu closes, so deselecting doesn’t yank the row mid-edit.
    @State private var pinnedOtherDeviceKeys: Set<String> = []

    /// 1 = “Other Devices” (unequalized outputs) disclosure open.
    @State private var otherDevicesListProgress: CGFloat = 0

    @State private var colorPickerIdentityKey: String?
    @State private var renamingIdentityKey: String?
    @State private var renameText = ""
    @State private var hoveringRenameKey: String?

    private var activeDevice: AudioOutputDevice? {
        appState.devices.first(where: \.isDefault)
            ?? appState.devices.first
    }

    private var otherDevices: [AudioOutputDevice] {
        appState.devices.filter { device in
            guard !device.isDefault else { return false }
            return appState.shouldListInactiveOutput(device.identityKey)
                || pinnedOtherDeviceKeys.contains(device.identityKey)
        }
    }

    /// Connected outputs with no EQ mapping yet — reachable via “Other Devices”.
    private var unlistedDevices: [AudioOutputDevice] {
        appState.devices.filter { device in
            guard !device.isDefault else { return false }
            let listed = appState.shouldListInactiveOutput(device.identityKey)
                || pinnedOtherDeviceKeys.contains(device.identityKey)
            return !listed
        }
    }

    private var activeMapping: OutputMapping {
        guard let key = activeDevice?.identityKey else { return OutputMapping() }
        return appState.config.mapping(forIdentity: key)
    }

    private var activeAccent: Color {
        guard let filename = activeMapping.profileFilename else {
            return Color(nsColor: .systemGray)
        }
        return appState.colorHex(forProfile: filename).asHexColor
    }

    private var isActivePanelVisible: Bool {
        activePanelProgress > 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            activeOutputHeader

            // System-default EQ panel (collapses when an inactive output is expanded).
            if let key = activeDevice?.identityKey {
                clippedEQPanel(
                    identityKey: key,
                    otherProfilesProgress: $activeOtherProfilesProgress,
                    progress: activePanelProgress,
                    showsLeadingDivider: true
                )
            }

            if !otherDevices.isEmpty {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
            }

            ForEach(otherDevices, id: \.identityKey) { device in
                otherDeviceSection(device)
                if device.identityKey != otherDevices.last?.identityKey {
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                }
            }

            if !unlistedDevices.isEmpty {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
                otherDevicesDisclosure
            }

            if appState.needsAudioPermission {
                Divider().padding(.horizontal, MenuChrome.dividerInset)
                permissionBanner
            }

            Divider().padding(.horizontal, MenuChrome.dividerInset)

            VStack(alignment: .leading, spacing: 0) {
                ControlCenterRow(title: "Settings…", style: .command) {
                    // Placeholder — hierarchy first; settings UI later.
                }

                ControlCenterRow(title: "Quit", style: .command) {
                    appState.quit()
                }
            }
            .padding(.top, MenuChrome.otherProfilesSectionVerticalPadding)
            .padding(.bottom, MenuChrome.menuPadding)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .focusEffectDisabled()
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
            beginPopoverSession()
        }
        .onChange(of: activeDevice?.identityKey) { _, _ in
            syncRenameText()
            pinOtherDevicesWithProfiles(reset: false)
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
        pinOtherDevicesWithProfiles(reset: true)
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
        onToggleExpand: @escaping () -> Void
    ) -> some View {
        let mapping = appState.config.mapping(forIdentity: device.identityKey)
        return HStack(spacing: 10) {
            outputTitle(device, isFocused: isFocused)

            // Empty header area expands/collapses (and dismisses a sticky rename).
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(minHeight: MenuChrome.textRowContentHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpand)

            Toggle(
                "",
                isOn: Binding(
                    get: { mapping.enabled },
                    set: { appState.setEnabled(forIdentity: device.identityKey, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .focusEffectDisabled()
            .focusable(false)
            .disabled(mapping.profileFilename == nil)
            .tint(accent)
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.top, topPadding)
        .padding(.bottom, MenuChrome.headerVerticalPadding)
    }

    @ViewBuilder
    private func outputTitle(_ device: AudioOutputDevice, isFocused: Bool) -> some View {
        let key = device.identityKey
        let isRenaming = renamingIdentityKey == key
        let isHovering = hoveringRenameKey == key

        if isRenaming, isFocused {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: MenuChrome.headerFontSize, weight: MenuChrome.headerWeight))
                .focused($focusedRenameID)
                .onSubmit { commitRename() }
                .onChange(of: focusedRenameID) { _, focused in
                    if !focused { commitRename() }
                }
                .onAppear { focusedRenameID = true }
                .padding(.vertical, 2)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        } else {
            Text(device.name)
                .font(.system(size: MenuChrome.headerFontSize, weight: MenuChrome.headerWeight))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHovering && isFocused ? 0.05 : 0))
                        .padding(.horizontal, -4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(isHovering && isFocused ? 0.35 : 0),
                            lineWidth: 1
                        )
                        .padding(.horizontal, -4)
                )
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .onHover { hovering in
                    hoveringRenameKey = hovering ? key : (hoveringRenameKey == key ? nil : hoveringRenameKey)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    handleTitleTap(device, isFocused: isFocused)
                }
        }
    }

    private func handleTitleTap(_ device: AudioOutputDevice, isFocused: Bool) {
        if isFocused {
            beginRename(device)
        } else if device.isDefault {
            focusActiveOutput(animated: true)
        } else {
            focusOtherDevice(device, animated: true)
        }
    }

    // MARK: - Shared EQ panel clip

    private func clippedEQPanel(
        identityKey: String,
        otherProfilesProgress: Binding<CGFloat>,
        progress: CGFloat,
        showsLeadingDivider: Bool
    ) -> some View {
        let height = OutputEQPanelMetrics.height(
            appState: appState,
            identityKey: identityKey,
            otherProfilesProgress: otherProfilesProgress.wrappedValue,
            showsLeadingDivider: showsLeadingDivider
        )
        return VStack(alignment: .leading, spacing: 0) {
            OutputEQPanel(
                identityKey: identityKey,
                otherProfilesProgress: otherProfilesProgress,
                colorPickerIdentityKey: $colorPickerIdentityKey,
                showsLeadingDivider: showsLeadingDivider,
                onToggleOtherProfiles: { delta in
                    popoverChrome.animateDisclosure(deltaHeight: delta * progress)
                }
            )
        }
        .frame(height: progress * height, alignment: .top)
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
                progress: isExpanded ? otherDevicePanelProgress : 0,
                showsLeadingDivider: true
            )
        }
    }

    /// Unequalized outputs (Wi‑Fi–style “Other Networks”).
    private var otherDevicesDisclosure: some View {
        let count = unlistedDevices.count
        let scrollHeight = UnlistedDevicesMetrics.scrollHeight(count: count)
        let bodyHeight = UnlistedDevicesMetrics.bodyHeight(count: count)
        let needsScroll = count > UnlistedDevicesMetrics.maxVisibleRows

        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: "Other Devices",
                style: .disclosure,
                trailing: otherDevicesListProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let expanding = otherDevicesListProgress < 0.5
                let target: CGFloat = expanding ? 1 : 0
                let delta = (target - otherDevicesListProgress) * bodyHeight
                popoverChrome.animateDisclosure(deltaHeight: delta)
                withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                    otherDevicesListProgress = target
                }
            }

            ScrollView(.vertical, showsIndicators: needsScroll) {
                VStack(alignment: .leading, spacing: UnlistedDevicesMetrics.rowSpacing) {
                    ForEach(unlistedDevices, id: \.identityKey) { device in
                        ControlCenterRow(title: device.name, style: .listItem) {
                            selectUnlistedDevice(device)
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
        // Match Other Profiles section chrome (padding above/below the disclosure).
        .padding(.vertical, MenuChrome.otherProfilesSectionVerticalPadding)
    }

    private func selectUnlistedDevice(_ device: AudioOutputDevice) {
        let collapseHeight =
            otherDevicesListProgress * UnlistedDevicesMetrics.bodyHeight(count: unlistedDevices.count)

        if otherDevicesListProgress > 0.01 {
            popoverChrome.animateDisclosure(deltaHeight: -collapseHeight)
            withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                otherDevicesListProgress = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + PopoverChrome.disclosureDuration) {
                pinnedOtherDeviceKeys.insert(device.identityKey)
                focusOtherDevice(device, animated: true)
            }
        } else {
            pinnedOtherDeviceKeys.insert(device.identityKey)
            focusOtherDevice(device, animated: true)
        }
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

    private func focusOtherDevice(_ device: AudioOutputDevice, animated: Bool) {
        let key = device.identityKey
        let activeKey = activeDevice?.identityKey
        let oldActive = activeKey.map {
            OutputEQPanelMetrics.height(
                appState: appState,
                identityKey: $0,
                otherProfilesProgress: activeOtherProfilesProgress,
                showsLeadingDivider: true
            ) * activePanelProgress
        } ?? 0
        let oldOther: CGFloat = {
            guard let existing = expandedOtherDeviceKey else { return 0 }
            return OutputEQPanelMetrics.height(
                appState: appState,
                identityKey: existing,
                otherProfilesProgress: inactiveOtherProfilesProgress,
                showsLeadingDivider: true
            ) * otherDevicePanelProgress
        }()
        let preferredOtherProfiles = preferredOtherProfilesProgress(for: key)
        let newOther = OutputEQPanelMetrics.height(
            appState: appState,
            identityKey: key,
            otherProfilesProgress: preferredOtherProfiles,
            showsLeadingDivider: true
        )
        let delta = newOther - oldActive - oldOther

        if animated {
            popoverChrome.animateDisclosure(deltaHeight: delta)
            withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                activePanelProgress = 0
                activeOtherProfilesProgress = 0
                expandedOtherDeviceKey = key
                otherDevicePanelProgress = 1
                inactiveOtherProfilesProgress = preferredOtherProfiles
                colorPickerIdentityKey = nil
                endRenameIfNeeded()
            }
        } else {
            activePanelProgress = 0
            activeOtherProfilesProgress = 0
            expandedOtherDeviceKey = key
            otherDevicePanelProgress = 1
            inactiveOtherProfilesProgress = preferredOtherProfiles
            colorPickerIdentityKey = nil
            endRenameIfNeeded()
        }
    }

    private func focusActiveOutput(animated: Bool) {
        let activeKey = activeDevice?.identityKey
        let preferredOtherProfiles = activeKey.map { preferredOtherProfilesProgress(for: $0) } ?? 0
        let oldOther: CGFloat = {
            guard let existing = expandedOtherDeviceKey else { return 0 }
            return OutputEQPanelMetrics.height(
                appState: appState,
                identityKey: existing,
                otherProfilesProgress: inactiveOtherProfilesProgress,
                showsLeadingDivider: true
            ) * otherDevicePanelProgress
        }()
        let newActive = activeKey.map {
            OutputEQPanelMetrics.height(
                appState: appState,
                identityKey: $0,
                otherProfilesProgress: preferredOtherProfiles,
                showsLeadingDivider: true
            )
        } ?? 0
        let oldActive = activeKey.map {
            OutputEQPanelMetrics.height(
                appState: appState,
                identityKey: $0,
                otherProfilesProgress: activeOtherProfilesProgress,
                showsLeadingDivider: true
            ) * activePanelProgress
        } ?? 0
        let delta = newActive - oldActive - oldOther

        if animated {
            popoverChrome.animateDisclosure(deltaHeight: delta)
            withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                activePanelProgress = 1
                activeOtherProfilesProgress = preferredOtherProfiles
                otherDevicePanelProgress = 0
                inactiveOtherProfilesProgress = 0
                colorPickerIdentityKey = nil
                endRenameIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + PopoverChrome.disclosureDuration) {
                if otherDevicePanelProgress < 0.01 {
                    expandedOtherDeviceKey = nil
                }
            }
        } else {
            activePanelProgress = 1
            activeOtherProfilesProgress = preferredOtherProfiles
            expandedOtherDeviceKey = nil
            otherDevicePanelProgress = 0
            inactiveOtherProfilesProgress = 0
            colorPickerIdentityKey = nil
            endRenameIfNeeded()
        }
    }

    /// No Profile → Other Profiles starts open so picking an EQ is one less click.
    private func preferredOtherProfilesProgress(for identityKey: String) -> CGFloat {
        appState.config.mapping(forIdentity: identityKey).profileFilename == nil ? 1 : 0
    }

    // MARK: - Shared chrome

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System audio access is required to apply EQ.")
                .font(.caption)
            HStack(spacing: 8) {
                Button("Open Settings") { appState.openAudioPermissionSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Quit & Reopen") { appState.quitAndRelaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, MenuChrome.contentInset)
        .padding(.vertical, MenuChrome.headerVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func pinOtherDevicesWithProfiles(reset: Bool) {
        let configured = Set(
            appState.devices.compactMap { device -> String? in
                guard !device.isDefault else { return nil }
                guard appState.shouldListInactiveOutput(device.identityKey) else { return nil }
                return device.identityKey
            }
        )
        if reset {
            pinnedOtherDeviceKeys = configured
        } else {
            pinnedOtherDeviceKeys.formUnion(configured)
        }
    }

    private func syncRenameText() {
        renamingIdentityKey = nil
        renameText = ""
        focusedRenameID = false
    }

    private func beginRename(_ device: AudioOutputDevice) {
        renamingIdentityKey = device.identityKey
        renameText = device.name
        focusedRenameID = true
    }

    private func endRenameIfNeeded() {
        guard renamingIdentityKey != nil else { return }
        commitRename()
    }

    private func commitRename() {
        let key = renamingIdentityKey
        defer {
            renamingIdentityKey = nil
            focusedRenameID = false
            renameText = ""
        }
        guard let key else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = appState.devices.first(where: { $0.identityKey == key })?.name
        if trimmed != current {
            appState.setDisplayName(forIdentity: key, name: trimmed)
        }
    }
}

// MARK: - Wi‑Fi / Control Center chrome metrics

private enum MenuChrome {
    static let contentInset: CGFloat = 16
    static let dividerInset: CGFloat = 16
    static let menuPadding: CGFloat = 10
    static let headerVerticalPadding: CGFloat = 10
    static let sectionTopPadding: CGFloat = 8
    static let sectionToContentSpacing: CGFloat = 6
    static let waveformSpacing: CGFloat = 6
    static let waveformBottomPadding: CGFloat = 8
    static let noProfileBottomPadding: CGFloat = 8
    static let otherProfilesSectionVerticalPadding: CGFloat = 6

    static let headerFontSize: CGFloat = 13
    static let bodyFontSize: CGFloat = 13
    /// Sub-header (“Active Profile”) and expanding headers (“Other Profiles”).
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

    static let textRowContentHeight: CGFloat = 20
    static let textRowHeight: CGFloat = 28
    static let iconRowHeight: CGFloat = 34
    static let sectionRowHeight: CGFloat = 24

    static let featuredIconSize: CGFloat = 26
    static let listIconSize: CGFloat = 18
    static let chevronSize: CGFloat = 10
    static let waveformHeight: CGFloat = 28

    static var highlightInset: CGFloat {
        if #available(macOS 26, *) { return 8 }
        return 5
    }

    static var highlightCornerRadius: CGFloat {
        if #available(macOS 26, *) { return 10 }
        return 5
    }
}

// MARK: - EQ panel (identical for active + inactive outputs)

private enum UnlistedDevicesMetrics {
    /// Match Other Profiles list rows (`iconRowHeight`), not footer command rows.
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
        if scroll <= 0 {
            return textRowHeight
        }
        return scroll + disclosureRowSpacing + textRowHeight
    }

    @MainActor
    static func height(
        appState: AppState,
        identityKey: String,
        otherProfilesProgress: CGFloat,
        showsLeadingDivider: Bool
    ) -> CGFloat {
        let mapping = appState.config.mapping(forIdentity: identityKey)
        let profiles = appState.profiles(forIdentity: identityKey)
        let otherCount = profiles.filter { $0.filename != mapping.profileFilename }.count
        let hasProfile = mapping.profileFilename != nil

        var height: CGFloat = 0
        if showsLeadingDivider {
            height += 1 // Divider visual weight (padded elsewhere; keep tiny)
        }

        // Active Profile block — matches OutputEQPanel layout.
        height += MenuChrome.sectionTopPadding
        height += MenuChrome.sectionRowHeight
        height += MenuChrome.sectionToContentSpacing
        height += iconRowHeight
        if hasProfile {
            height += MenuChrome.waveformSpacing + MenuChrome.waveformHeight + MenuChrome.waveformBottomPadding
        } else {
            height += MenuChrome.noProfileBottomPadding
        }

        height += MenuChrome.otherProfilesSectionVerticalPadding
        height += disclosureRowHeight // “Other Profiles” header
        height += otherProfilesProgress * otherProfilesExpandedBodyHeight(profileCount: otherCount)
        height += MenuChrome.otherProfilesSectionVerticalPadding
        return height
    }
}

private struct OutputEQPanel: View {
    @EnvironmentObject private var appState: AppState
    let identityKey: String
    @Binding var otherProfilesProgress: CGFloat
    @Binding var colorPickerIdentityKey: String?
    var showsLeadingDivider: Bool = true
    var onToggleOtherProfiles: (CGFloat) -> Void

    private var mapping: OutputMapping {
        appState.config.mapping(forIdentity: identityKey)
    }

    private var profiles: [ProfileFile] {
        appState.profiles(forIdentity: identityKey)
    }

    private var otherProfiles: [ProfileFile] {
        profiles.filter { $0.filename != mapping.profileFilename }
    }

    private var hasProfile: Bool {
        mapping.profileFilename != nil
    }

    /// Same animated blob as the menu-bar icon — only for the live system output while EQ is engaged.
    private var isLiveEQBlob: Bool {
        hasProfile
            && appState.isEQEngaged
            && identityKey == appState.defaultIdentityKey
    }

    private var profileTitle: String {
        guard let filename = mapping.profileFilename else { return "No Profile" }
        if let profile = profiles.first(where: { $0.filename == filename }) {
            return profile.displayName
        }
        return (filename as NSString).deletingPathExtension
    }

    private var accent: Color {
        guard let filename = mapping.profileFilename else {
            return Color(nsColor: .systemGray)
        }
        return appState.colorHex(forProfile: filename).asHexColor
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

            otherProfilesSection
                .padding(.vertical, MenuChrome.otherProfilesSectionVerticalPadding)
        }
        .onAppear {
            expandOtherProfilesWhenNoProfile(animated: false)
        }
        .onChange(of: mapping.profileFilename) { oldFilename, filename in
            if filename == nil {
                if otherProfilesProgress < 0.5 {
                    expandOtherProfilesWhenNoProfile(animated: true)
                } else {
                    // List already open — still need to animate waveform out / row back in.
                    animateProfilePresenceHeightChange(fromNoProfile: false)
                }
            } else if oldFilename == nil {
                // No Profile → selection: waveform in, one other-profile row out.
                animateProfilePresenceHeightChange(fromNoProfile: true)
            }
        }
    }

    private func expandOtherProfilesWhenNoProfile(animated: Bool) {
        guard mapping.profileFilename == nil, otherProfilesProgress < 0.5 else { return }
        let listHeight = OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: otherProfiles.count)
        let delta = (1 - otherProfilesProgress) * listHeight
        if animated {
            onToggleOtherProfiles(delta)
            withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                otherProfilesProgress = 1
            }
        } else {
            otherProfilesProgress = 1
        }
    }

    /// Keep panel height in sync when Active Profile appears/disappears while Other Profiles stays expanded.
    private func animateProfilePresenceHeightChange(fromNoProfile: Bool) {
        let afterOtherCount = otherProfiles.count
        let beforeOtherCount = fromNoProfile ? afterOtherCount + 1 : max(0, afterOtherCount - 1)
        let beforeHasProfile = !fromNoProfile
        let afterHasProfile = fromNoProfile

        let progress = otherProfilesProgress
        let activeDelta =
            Self.activeProfileBlockHeight(hasProfile: afterHasProfile)
            - Self.activeProfileBlockHeight(hasProfile: beforeHasProfile)
        let otherDelta = progress * (
            OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: afterOtherCount)
            - OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: beforeOtherCount)
        )
        let delta = activeDelta + otherDelta
        guard abs(delta) > 0.5 else { return }
        onToggleOtherProfiles(delta)
    }

    private static func activeProfileBlockHeight(hasProfile: Bool) -> CGFloat {
        // Must match OutputEQPanelMetrics / activeProfileSection layout.
        var height: CGFloat =
            MenuChrome.sectionTopPadding
            + MenuChrome.sectionRowHeight
            + MenuChrome.sectionToContentSpacing
            + MenuChrome.iconRowHeight
        if hasProfile {
            height += MenuChrome.waveformSpacing + MenuChrome.waveformHeight + MenuChrome.waveformBottomPadding
        } else {
            height += MenuChrome.noProfileBottomPadding
        }
        return height
    }

    private var activeProfileSection: some View {
        VStack(alignment: .leading, spacing: MenuChrome.sectionToContentSpacing) {
            Text("Active Profile")
                .font(MenuChrome.sectionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.sectionTopPadding)

            ActiveProfileRow(
                title: profileTitle,
                accent: accent,
                hasProfile: hasProfile,
                animatesBlob: isLiveEQBlob,
                showColorPicker: showColorPicker,
                colorPicker: { colorPopover }
            ) {
                guard hasProfile else { return }
                appState.setProfile(forIdentity: identityKey, filename: nil)
            }
            .padding(.bottom, hasProfile ? 0 : MenuChrome.noProfileBottomPadding)

            if hasProfile {
                ProfileWaveformView(
                    magnitudesDB: appState.eqFrequencyResponse(forIdentity: identityKey),
                    color: accent
                )
                .frame(height: MenuChrome.waveformHeight)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.waveformSpacing - MenuChrome.sectionToContentSpacing)
                .padding(.bottom, MenuChrome.waveformBottomPadding)
            }
        }
    }

    private var otherProfilesSection: some View {
        let profileCount = otherProfiles.count
        let scrollHeight = OutputEQPanelMetrics.otherProfilesScrollHeight(profileCount: profileCount)
        let bodyHeight = OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: profileCount)
        let needsScroll = profileCount > OutputEQPanelMetrics.maxVisibleOtherProfileRows

        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: "Other Profiles",
                style: .disclosure,
                trailing: otherProfilesProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let expanding = otherProfilesProgress < 0.5
                let target: CGFloat = expanding ? 1 : 0
                let delta = (target - otherProfilesProgress) * bodyHeight
                onToggleOtherProfiles(delta)
                withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                    otherProfilesProgress = target
                }
            }

            VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                if scrollHeight > 0 {
                    ScrollView(.vertical, showsIndicators: needsScroll) {
                        VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                            ForEach(otherProfiles) { profile in
                                OtherProfileRow(
                                    profile: profile,
                                    color: appState.colorHex(forProfile: profile.filename).asHexColor
                                ) {
                                    appState.setProfile(forIdentity: identityKey, filename: profile.filename)
                                }
                            }
                        }
                    }
                    .frame(height: scrollHeight, alignment: .top)
                    .scrollBounceBehavior(.basedOnSize)
                }

                // Sticky under the scrolling list (Wi‑Fi–style).
                ControlCenterRow(title: "Change Folder…", style: .command) {
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
        let selectedHex = activeFilename.map { appState.colorHex(forProfile: $0) } ?? mapping.colorHex
        return HStack(spacing: 10) {
            ForEach(ProfileColorPalette.swatches, id: \.self) { hex in
                Circle()
                    .fill(hex.asHexColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if selectedHex.lowercased() == hex.lowercased() {
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
}

// MARK: - EQ frequency-response curve

private struct ProfileWaveformView: View {
    let magnitudesDB: [Double]?
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let magnitudesDB, magnitudesDB.count >= 2 else {
                var flat = Path()
                let y = size.height * 0.55
                flat.move(to: CGPoint(x: 0, y: y))
                flat.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    flat,
                    with: .color(color.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                return
            }

            let minDB = magnitudesDB.min() ?? -6
            let maxDB = magnitudesDB.max() ?? 6
            let pad = 1.5
            var lo = minDB - pad
            var hi = maxDB + pad
            if hi - lo < 6 {
                let mid = (hi + lo) / 2
                lo = mid - 3
                hi = mid + 3
            }

            var path = Path()
            let last = magnitudesDB.count - 1
            for (i, db) in magnitudesDB.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(last)
                let t = (db - lo) / (hi - lo)
                let y = size.height * (1 - CGFloat(t))
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityLabel("EQ frequency response")
    }
}

// MARK: - Control Center rows

private enum ControlCenterTrailing {
    case none
    case chevronRight
    case chevronDown
}

private enum ControlCenterRowStyle {
    /// Footer / Change Folder — 13 regular, text-only height.
    case command
    /// Other Devices list rows — same height as Other Profiles items.
    case listItem
    /// “Other Profiles” / “Other Devices” — 12 bold secondary + chevron.
    case disclosure
}

private struct ActiveProfileRow<ColorPicker: View>: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let accent: Color
    let hasProfile: Bool
    var animatesBlob: Bool = false
    @Binding var showColorPicker: Bool
    @ViewBuilder let colorPicker: () -> ColorPicker
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
                    Group {
                        if animatesBlob {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                                let level = CGFloat(appState.audioEngine.outputLevel)
                                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
                                    * (2.2 + Double(level) * 4)
                                AnimatedEQBlobView(
                                    color: accent,
                                    level: level,
                                    phase: CGFloat(phase),
                                    size: MenuChrome.featuredIconSize
                                )
                            }
                        } else {
                            Circle()
                                .fill(hasProfile ? accent : Color.primary.opacity(0.12))
                                .frame(width: MenuChrome.featuredIconSize, height: MenuChrome.featuredIconSize)
                        }
                    }
                    .frame(width: MenuChrome.featuredIconSize, height: MenuChrome.featuredIconSize)
                }
                .buttonStyle(.plain)
                .disabled(!hasProfile)
                .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                    colorPicker()
                }

                Button(action: onDeselect) {
                    Text(title)
                        .font(MenuChrome.bodyFont)
                        .fontWeight(.regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(MenuChrome.bodyFont)
                .disabled(!hasProfile)
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

/// Menu-popover twin of the status-item blob (same geometry as `EQBlob` / menu bar icon).
private struct AnimatedEQBlobView: View {
    let color: Color
    let level: CGFloat
    let phase: CGFloat
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let inset: CGFloat = 1
            let draw = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)
            let center = CGPoint(x: draw.midX, y: draw.midY)
            let radius = min(draw.width, draw.height) / 2 * 0.92
            let path = EQBlob.swiftUIPath(
                center: center,
                radius: radius,
                level: level,
                phase: phase
            )
            // Soft halo like the status item when engaged.
            context.stroke(
                path,
                with: .color(Color.primary.opacity(0.22)),
                lineWidth: 2.2
            )
            context.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

private struct OtherProfileRow: View {
    let title: String
    let color: Color
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    init(profile: ProfileFile, color: Color, action: @escaping () -> Void) {
        self.title = profile.displayName
        self.color = color
        self.isEnabled = true
        self.action = action
    }

    init(
        title: String,
        color: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.color = color
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, MenuChrome.highlightInset)

                HStack(spacing: 10) {
                    Circle()
                        .fill(color)
                        .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
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
    }
}

private struct ControlCenterRow: View {
    let title: String
    var style: ControlCenterRowStyle = .command
    var trailing: ControlCenterTrailing = .none
    let action: () -> Void

    @State private var isHovering = false

    private var rowHeight: CGFloat {
        switch style {
        case .command: return MenuChrome.textRowHeight
        case .listItem: return MenuChrome.iconRowHeight
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
        case .command, .listItem: return .primary
        case .disclosure: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MenuChrome.highlightCornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, MenuChrome.highlightInset)

                HStack(spacing: 0) {
                    Text(title)
                        .font(titleFont)
                        .fontWeight(style == .disclosure ? .bold : .regular)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    switch trailing {
                    case .none:
                        EmptyView()
                    case .chevronRight:
                        Image(systemName: "chevron.right")
                            .font(.system(size: MenuChrome.chevronSize, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    case .chevronDown:
                        Image(systemName: "chevron.down")
                            .font(.system(size: MenuChrome.chevronSize, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, MenuChrome.contentInset)
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(titleFont)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}
