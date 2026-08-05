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

    @State private var colorPickerIdentityKey: String?
    @State private var renameText = ""
    @State private var isEditingTitle = false
    @State private var isHoveringTitle = false

    private var activeDevice: AudioOutputDevice? {
        appState.devices.first(where: \.isDefault)
            ?? appState.devices.first
    }

    private var otherDevices: [AudioOutputDevice] {
        appState.devices.filter { device in
            guard !device.isDefault else { return false }
            let hasProfile = appState.config.mapping(forIdentity: device.identityKey).profileFilename != nil
            return hasProfile || pinnedOtherDeviceKeys.contains(device.identityKey)
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
                Divider().padding(.horizontal, 12)
            }

            ForEach(otherDevices, id: \.identityKey) { device in
                otherDeviceSection(device)
                if device.identityKey != otherDevices.last?.identityKey {
                    Divider().padding(.horizontal, 12)
                }
            }

            if appState.needsAudioPermission {
                Divider().padding(.horizontal, 12)
                permissionBanner
            }

            Divider().padding(.horizontal, 12)

            ControlCenterRow(title: "Settings…") {
                // Placeholder — hierarchy first; settings UI later.
            }
            .padding(.horizontal, 6)

            ControlCenterRow(title: "Quit") {
                appState.quit()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
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
    }

    private func beginPopoverSession() {
        pinOtherDevicesWithProfiles(reset: true)
        focusActiveOutput(animated: false)
    }

    // MARK: - Active output header

    private var activeOutputHeader: some View {
        HStack(spacing: 10) {
            activeTitle
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleActiveOutputTap)

            if let device = activeDevice {
                let mapping = appState.config.mapping(forIdentity: device.identityKey)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { mapping.enabled },
                        set: { appState.setEnabled(forIdentity: device.identityKey, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .focusEffectDisabled()
                .focusable(false)
                .disabled(mapping.profileFilename == nil)
                .tint(activeAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func handleActiveOutputTap() {
        if isActivePanelVisible {
            isEditingTitle = true
        } else {
            focusActiveOutput(animated: true)
        }
    }

    @ViewBuilder
    private var activeTitle: some View {
        if isEditingTitle, isActivePanelVisible {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($focusedRenameID)
                .onSubmit { commitRename() }
                .onChange(of: focusedRenameID) { _, focused in
                    if !focused { commitRename() }
                }
                .onAppear { focusedRenameID = true }
        } else {
            Text(activeDevice?.name ?? "No Output")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHoveringTitle && isActivePanelVisible ? 0.05 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(isHoveringTitle && isActivePanelVisible ? 0.35 : 0),
                            lineWidth: 1
                        )
                )
                .onHover { isHoveringTitle = $0 }
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

    private func otherDeviceHeader(
        _ device: AudioOutputDevice,
        mapping: OutputMapping,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleOtherDevice(device)
            } label: {
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isExpanded ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Toggle(
                "",
                isOn: Binding(
                    get: { mapping.enabled },
                    set: { appState.setEnabled(forIdentity: device.identityKey, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .focusEffectDisabled()
            .focusable(false)
            .disabled(mapping.profileFilename == nil)
            .tint(Color(nsColor: .systemGray))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        let newOther = OutputEQPanelMetrics.height(
            appState: appState,
            identityKey: key,
            otherProfilesProgress: 0,
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
                inactiveOtherProfilesProgress = 0
                colorPickerIdentityKey = nil
                isEditingTitle = false
            }
        } else {
            activePanelProgress = 0
            activeOtherProfilesProgress = 0
            expandedOtherDeviceKey = key
            otherDevicePanelProgress = 1
            inactiveOtherProfilesProgress = 0
            colorPickerIdentityKey = nil
            isEditingTitle = false
        }
    }

    private func focusActiveOutput(animated: Bool) {
        let activeKey = activeDevice?.identityKey
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
                otherProfilesProgress: 0,
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
                activeOtherProfilesProgress = 0
                otherDevicePanelProgress = 0
                inactiveOtherProfilesProgress = 0
                colorPickerIdentityKey = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + PopoverChrome.disclosureDuration) {
                if otherDevicePanelProgress < 0.01 {
                    expandedOtherDeviceKey = nil
                }
            }
        } else {
            activePanelProgress = 1
            activeOtherProfilesProgress = 0
            expandedOtherDeviceKey = nil
            otherDevicePanelProgress = 0
            inactiveOtherProfilesProgress = 0
            colorPickerIdentityKey = nil
        }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func pinOtherDevicesWithProfiles(reset: Bool) {
        let profiled = Set(
            appState.devices.compactMap { device -> String? in
                guard !device.isDefault else { return nil }
                guard appState.config.mapping(forIdentity: device.identityKey).profileFilename != nil
                else { return nil }
                return device.identityKey
            }
        )
        if reset {
            pinnedOtherDeviceKeys = profiled
        } else {
            pinnedOtherDeviceKeys.formUnion(profiled)
        }
    }

    private func syncRenameText() {
        renameText = activeDevice?.name ?? ""
        isEditingTitle = false
    }

    private func commitRename() {
        defer {
            isEditingTitle = false
            focusedRenameID = false
            syncRenameText()
        }
        guard let key = activeDevice?.identityKey else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != activeDevice?.name {
            appState.setDisplayName(forIdentity: key, name: trimmed)
        }
    }
}

// MARK: - EQ panel (identical for active + inactive outputs)

private enum OutputEQPanelMetrics {
    static let disclosureRowHeight: CGFloat = 34
    static let disclosureRowSpacing: CGFloat = 2

    static func otherProfilesListHeight(count: Int) -> CGFloat {
        let c = CGFloat(count)
        return c * disclosureRowHeight + max(0, c - 1) * disclosureRowSpacing
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
        height += 8 // heading top pad
        height += 15 // heading
        height += 8 // spacing
        height += 34 // profile row
        if hasProfile {
            height += 8 + 28 + 10 // spacing + curve + bottom
        } else {
            height += 10
        }

        height += 6 // other-profiles section vertical pad top
        height += disclosureRowHeight // “Other Profiles” header
        height += otherProfilesProgress * otherProfilesListHeight(count: otherCount + 1)
        height += 6 // vertical pad bottom
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
                Divider().padding(.horizontal, 12)
            }

            activeProfileSection

            otherProfilesSection
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }

    private var activeProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Profile")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            ActiveProfileRow(
                title: profileTitle,
                accent: accent,
                hasProfile: hasProfile,
                showColorPicker: showColorPicker,
                colorPicker: { colorPopover }
            ) {
                guard hasProfile else { return }
                appState.setProfile(forIdentity: identityKey, filename: nil)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, hasProfile ? 0 : 10)

            if hasProfile {
                ProfileWaveformView(
                    magnitudesDB: appState.eqFrequencyResponse(forIdentity: identityKey),
                    color: accent
                )
                .frame(height: 28)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    private var otherProfilesSection: some View {
        let listHeight = OutputEQPanelMetrics.otherProfilesListHeight(count: otherProfiles.count + 1)
        return VStack(alignment: .leading, spacing: 2) {
            ControlCenterRow(
                title: "Other Profiles",
                titleWeight: .semibold,
                trailing: otherProfilesProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let expanding = otherProfilesProgress < 0.5
                let target: CGFloat = expanding ? 1 : 0
                let delta = (target - otherProfilesProgress) * listHeight
                onToggleOtherProfiles(delta)
                withAnimation(.easeInOut(duration: PopoverChrome.disclosureDuration)) {
                    otherProfilesProgress = target
                }
            }

            VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                ForEach(otherProfiles) { profile in
                    OtherProfileRow(
                        profile: profile,
                        color: appState.colorHex(forProfile: profile.filename).asHexColor
                    ) {
                        appState.setProfile(forIdentity: identityKey, filename: profile.filename)
                    }
                    .frame(height: OutputEQPanelMetrics.disclosureRowHeight, alignment: .leading)
                }
                ControlCenterRow(title: "Change Folder…") {
                    appState.chooseProfilesFolder(forIdentity: identityKey)
                }
                .frame(height: OutputEQPanelMetrics.disclosureRowHeight, alignment: .leading)
            }
            .frame(height: otherProfilesProgress * listHeight, alignment: .top)
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

private struct ActiveProfileRow<ColorPicker: View>: View {
    let title: String
    let accent: Color
    let hasProfile: Bool
    @Binding var showColorPicker: Bool
    @ViewBuilder let colorPicker: () -> ColorPicker
    let onDeselect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard hasProfile else { return }
                showColorPicker = true
            } label: {
                Circle()
                    .fill(hasProfile ? accent : Color.primary.opacity(0.12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!hasProfile)
            .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                colorPicker()
            }

            Button(action: onDeselect) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasProfile)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering && hasProfile ? Color.primary.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering && hasProfile
        }
        .focusEffectDisabled()
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
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

private struct ControlCenterRow: View {
    let title: String
    var titleWeight: Font.Weight = .regular
    var titleColor: Color = .primary
    var trailing: ControlCenterTrailing = .none
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: titleWeight))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                switch trailing {
                case .none:
                    EmptyView()
                case .chevronRight:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                case .chevronDown:
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}
