import AudiochromeCore
import AppKit
import SwiftUI

/// Menu hierarchy mirrors Control Center Wi‑Fi:
/// active output + toggle → EQ panel → other outputs (same EQ panel when expanded) → footer.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome

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

    /// Connected outputs with no EQ mapping yet — reachable via “Other Devices”.
    /// Same membership in both modes (non-default, not already shown as an EQ row).
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
        ).asHexColor
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
                    progress: activePanelProgress
                )
            }

            Group {
                ForEach(otherDevices, id: \.identityKey) { device in
                    otherDeviceSection(device)
                    if device.identityKey != otherDevices.last?.identityKey {
                        Divider().padding(.horizontal, MenuChrome.dividerInset)
                    }
                }

                if !unlistedDevices.isEmpty {
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                    otherDevicesDisclosure
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                } else if !otherDevices.isEmpty {
                    Divider().padding(.horizontal, MenuChrome.dividerInset)
                }

                ControlCenterRow(title: "Settings…", style: .command) {
                    popoverChrome.present(.settings)
                }
                .padding(.top, MenuChrome.waveformSpacing)
            }
            .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
            .disabled(appState.needsAudioPermission)

            ControlCenterRow(title: "Quit", style: .command) {
                appState.quit()
            }

            if appState.needsAudioPermission {
                ControlCenterRow(title: "Quit & Relaunch", style: .command) {
                    appState.quitAndRelaunch()
                }
            }
        }
        .padding(.bottom, MenuChrome.menuPadding)
        .frame(maxWidth: .infinity, alignment: .top)
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
        let isRenaming = renamingIdentityKey == device.identityKey

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

                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            // Armed in config isn’t “on” if EQ can’t run (e.g. no audio permission).
                            if device.isDefault, appState.needsAudioPermission {
                                return false
                            }
                            return mapping.enabled
                        },
                        set: { appState.setEnabled(forIdentity: device.identityKey, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .focusEffectDisabled()
                .focusable(false)
                .disabled(mapping.profileFilename == nil)
                .tint(accent)
                .layoutPriority(1)
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
            Text(isFocused ? "\(device.name) EQ" : device.name)
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
        let height = OutputEQPanelMetrics.height(
            appState: appState,
            identityKey: identityKey,
            otherProfilesProgress: otherProfilesProgress.wrappedValue,
            showsLeadingDivider: false
        )
        return MenuGroupedSection {
            OutputEQPanel(
                identityKey: identityKey,
                otherProfilesProgress: otherProfilesProgress,
                colorPickerIdentityKey: $colorPickerIdentityKey,
                showsLeadingDivider: false
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
                title: "Other Devices",
                style: .disclosure,
                trailing: otherDevicesListProgress > 0.5 ? .chevronDown : .chevronRight
            ) {
                let target: CGFloat = otherDevicesListProgress < 0.5 ? 1 : 0
                popoverChrome.animatingDisclosure {
                    otherDevicesListProgress = target
                }
            }

            ScrollView(.vertical, showsIndicators: needsScroll) {
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
        if otherDevicesListProgress > 0.01 {
            popoverChrome.animatingDisclosure {
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
        if animated {
            popoverChrome.animatingDisclosure {
                activePanelProgress = 0
                activeOtherProfilesProgress = 0
                expandedOtherDeviceKey = key
                otherDevicePanelProgress = 1
                inactiveOtherProfilesProgress = 0
                colorPickerIdentityKey = nil
                if renamingIdentityKey != key {
                    endRenameIfNeeded()
                }
            }
        } else {
            activePanelProgress = 0
            activeOtherProfilesProgress = 0
            expandedOtherDeviceKey = key
            otherDevicePanelProgress = 1
            inactiveOtherProfilesProgress = 0
            colorPickerIdentityKey = nil
            if renamingIdentityKey != key {
                endRenameIfNeeded()
            }
        }
    }

    private func focusActiveOutput(animated: Bool) {
        let activeKey = activeDevice?.identityKey
        if animated {
            popoverChrome.animatingDisclosure {
                activePanelProgress = 1
                activeOtherProfilesProgress = 0
                otherDevicePanelProgress = 0
                inactiveOtherProfilesProgress = 0
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
            activePanelProgress = 1
            activeOtherProfilesProgress = 0
            expandedOtherDeviceKey = nil
            otherDevicePanelProgress = 0
            inactiveOtherProfilesProgress = 0
            colorPickerIdentityKey = nil
            if let renamingIdentityKey, renamingIdentityKey != activeKey {
                endRenameIfNeeded()
            }
        }
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
    static let logoHeight: CGFloat = 20
    static let logoBreakBottomPadding: CGFloat = 9
    static let logoBreakTopPadding: CGFloat = 28
    /// Dimmed chrome below the audio-permission CTA.
    static let permissionLockedOpacity: Double = 0.4

    static let headerFontSize: CGFloat = 13
    static let bodyFontSize: CGFloat = 13
    /// Sub-header (“Active Profile”) and expanding headers (“Available Profiles”).
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

    static let listIconSize: CGFloat = 18
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

    /// “Active Profile” header + row + optional waveform + Create New Profile.
    static func activeProfileBlockHeight(hasProfile: Bool) -> CGFloat {
        var height = MenuChrome.sectionTopPadding
            + MenuChrome.sectionRowHeight
            + iconRowHeight
        if hasProfile {
            height += MenuChrome.waveformSpacing
                + MenuChrome.waveformHeight
                + MenuChrome.waveformSpacing
        }
        height += iconRowHeight
        return height
    }

    /// Permission slot: Active Profile header + message row + settings pill.
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

        if appState.needsAudioPermission {
            height += audioPermissionBlockHeight()
        } else {
            height += activeProfileBlockHeight(hasProfile: hasProfile)
        }

        height += MenuChrome.otherProfilesSectionVerticalPadding
        height += disclosureRowHeight // Available Profiles header
        height += otherProfilesProgress * otherProfilesExpandedBodyHeight(profileCount: otherCount)
        height += MenuChrome.otherProfilesSectionVerticalPadding
        return height
    }
}

private struct OutputEQPanel: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var popoverChrome: PopoverChrome
    let identityKey: String
    @Binding var otherProfilesProgress: CGFloat
    @Binding var colorPickerIdentityKey: String?
    var showsLeadingDivider: Bool = true
    @State private var isProfileDropTargeted = false

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
        return appState.colorHex(forProfile: filename, forIdentity: identityKey).asHexColor
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
                .opacity(appState.needsAudioPermission ? MenuChrome.permissionLockedOpacity : 1)
                .disabled(appState.needsAudioPermission)
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
            if imported {
                popoverChrome.animatingDisclosure {
                    // Active profile replaced — collapse Available Profiles like a normal pick.
                    otherProfilesProgress = 0
                }
            }
            return imported
        } isTargeted: { targeted in
            isProfileDropTargeted = targeted
        }
    }

    private var activeProfileSection: some View {
        Group {
            if appState.needsAudioPermission {
                audioPermissionPlaceholder
                    .frame(
                        height: OutputEQPanelMetrics.audioPermissionBlockHeight(),
                        alignment: .top
                    )
            } else {
                let blockHeight = OutputEQPanelMetrics.activeProfileBlockHeight(hasProfile: hasProfile)
                VStack(alignment: .leading, spacing: 0) {
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
                        showColorPicker: showColorPicker,
                        colorPicker: { colorPopover },
                        onEdit: hasProfile ? { openEditEditor() } : nil
                    ) {
                        guard hasProfile else { return }
                        popoverChrome.animatingDisclosure {
                            appState.setProfile(forIdentity: identityKey, filename: nil)
                        }
                    }

                    if hasProfile {
                        ProfileWaveformView(
                            preview: appState.eqFrequencyResponse(forIdentity: identityKey),
                            color: accent
                        )
                        .frame(height: MenuChrome.waveformHeight)
                        .padding(.horizontal, MenuChrome.contentInset)
                        .padding(.top, MenuChrome.waveformSpacing)
                        .padding(.bottom, MenuChrome.waveformSpacing)
                    }

                    PlusCommandRow(title: "Create New Profile", action: openCreateEditor)
                }
                .frame(height: blockHeight, alignment: .top)
            }
        }
    }

    /// Active Profile header + status line + Privacy & Security pill.
    private var audioPermissionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Active Profile")
                .font(MenuChrome.sectionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MenuChrome.sectionRowHeight, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)
                .padding(.top, MenuChrome.sectionTopPadding)

            Text("System audio access required to EQ")
                .font(MenuChrome.bodyFont)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MenuChrome.iconRowHeight, alignment: .leading)
                .padding(.horizontal, MenuChrome.contentInset)

            PermissionActionPillButton(title: "Privacy & Security Settings", showsExternalLink: true) {
                appState.openAudioPermissionSettings()
            }
            .padding(.horizontal, MenuChrome.contentInset)
            .padding(.top, MenuChrome.waveformSpacing)
            .padding(.bottom, MenuChrome.waveformBottomPadding)
        }
    }

    private var otherProfilesSection: some View {
        let profileCount = otherProfiles.count
        let scrollHeight = OutputEQPanelMetrics.otherProfilesScrollHeight(profileCount: profileCount)
        let bodyHeight = OutputEQPanelMetrics.otherProfilesExpandedBodyHeight(profileCount: profileCount)
        let needsScroll = profileCount > OutputEQPanelMetrics.maxVisibleOtherProfileRows

        return VStack(alignment: .leading, spacing: 0) {
            ControlCenterRow(
                title: "Available Profiles",
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
                    ScrollView(.vertical, showsIndicators: needsScroll) {
                        VStack(alignment: .leading, spacing: OutputEQPanelMetrics.disclosureRowSpacing) {
                            ForEach(otherProfiles) { profile in
                                OtherProfileRow(
                                    profile: profile,
                                    color: appState.colorHex(
                                        forProfile: profile.filename,
                                        forIdentity: identityKey
                                    ).asHexColor
                                ) {
                                    popoverChrome.animatingDisclosure {
                                        appState.setProfile(forIdentity: identityKey, filename: profile.filename)
                                    }
                                } onDelete: {
                                    popoverChrome.animatingDisclosure {
                                        appState.deleteProfile(profile, forIdentity: identityKey)
                                    }
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
        let selectedHex = activeFilename.map {
            appState.colorHex(forProfile: $0, forIdentity: identityKey)
        } ?? mapping.colorHex
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

// MARK: - EQ frequency-response curve

struct ProfileWaveformView: View {
    let preview: EQFrequencyResponsePreview?
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    private static let verticalInset: CGFloat = 2
    private static let strokeWidth: CGFloat = 1.25
    private static let halfRangeDB: Double = EQProfile.waveformRangeDB / 2
    private static let underCurveTopOpacity: Double = 0.32
    private static let curveBlackOverlayOpacity: Double = 0.20

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

            guard let preview, preview.magnitudesDB.count >= 2 else {
                var flat = Path()
                let y = plot.midY
                flat.move(to: CGPoint(x: plot.minX, y: y))
                flat.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(flat, with: .color(Color.primary.opacity(0.35)), style: style)
                return
            }

            let magnitudesDB = preview.magnitudesDB
            let half = Self.halfRangeDB
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

            // Profile color with a 20% black overlay.
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
}

/// Filled pill matching command-row height.
private struct PermissionActionPillButton: View {
    let title: String
    var showsExternalLink: Bool = false
    let action: () -> Void
    @State private var isHovering = false

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
            .padding(.horizontal, MenuChrome.contentInset)
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
    let hasProfile: Bool
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
                    Circle()
                        .fill(hasProfile ? accent : Color.primary.opacity(0.12))
                        .frame(width: MenuChrome.listIconSize, height: MenuChrome.listIconSize)
                }
                .buttonStyle(.plain)
                .disabled(!hasProfile)
                .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                    colorPicker()
                }

                Text(title)
                    .font(MenuChrome.bodyFont)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard hasProfile else { return }
                        onDeselect()
                    }

                if hasProfile, let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
    let color: Color
    var isEnabled: Bool = true
    let action: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false

    init(
        profile: ProfileFile,
        color: Color,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = profile.displayName
        self.color = color
        self.isEnabled = true
        self.action = action
        self.onDelete = onDelete
    }

    init(
        title: String,
        color: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.color = color
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
        .contextMenu {
            if let onDelete {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

struct ControlCenterRow: View {
    let title: String
    var style: ControlCenterRowStyle = .command
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

/// Plus-in-circle from the 37×37 create-profile SVG, drawn at swatch size.
private struct PlusCircleIcon: View {
    var body: some View {
        PlusCircleShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
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

/// Matches the provided 17×17 external-link SVG (box + arrow).
struct ExternalLinkIcon: View {
    var body: some View {
        ExternalLinkShape()
            .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: MenuChrome.chevronSize, height: MenuChrome.chevronSize)
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
