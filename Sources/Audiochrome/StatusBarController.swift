import AppKit
import AudiochromeCore
import Combine
import QuartzCore
import SwiftUI

/// AppKit status item with a Control Center–style panel (not NSPopover).
/// Panel is created lazily on first open so launch/audio startup stays responsive.
@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var panel: StatusMenuPanel?
    private var hostingController: NSHostingController<MenuBarRoot>?
    private var menuChrome: PopoverChrome?
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var animationTimer: Timer?
    private var animPhase: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var statusItemClickMonitor: Any?
    private var isPresented = false
    /// Captured during the click while the status-item window is valid.
    private var pendingAnchorRect: NSRect?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        appState.onWillPresentModal = { [weak self] in
            self?.closeMenu()
        }
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist ⌘-dragged menu-bar position across launches (macOS 12+).
        item.autosaveName = "app.audiochrome.Audiochrome.statusItem"
        statusItem = item

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.appearsDisabled = false
            // No toolTip — stock menu-bar extras don’t show hover tips over the icon.
            // No target/action — we swallow mouseDown ourselves so AppKit never
            // runs its highlight→mouseUp-clear cycle.

            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshIcon()
                }
            }
        }

        installStatusItemClickMonitor()

        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncAnimationTimer()
                    self?.refreshIcon()
                }
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIcon()
            }
        }

        // Match Wi‑Fi / Control Center: close when the user changes Spaces.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeMenu()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncAnimationTimer()
            self?.refreshIcon()
            DispatchQueue.main.async { [weak self] in
                self?.refreshIcon()
            }
        }
    }

    /// Swallow status-item mouseDown so we fully own the selected highlight.
    private func installStatusItemClickMonitor() {
        statusItemClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let button = self.statusItem?.button, event.window === button.window else {
                return event
            }
            // ⌘-click is reserved for system menu-bar icon drag/reorder — don’t swallow it.
            if event.type == .leftMouseDown, event.modifierFlags.contains(.command) {
                if self.isPresented { self.closeMenu() }
                self.setStatusItemHighlighted(false)
                return event
            }
            self.handleStatusItemMouseDown(event)
            return nil
        }
    }

    private func handleStatusItemMouseDown(_ event: NSEvent) {
        let isRightClick =
            event.type == .rightMouseDown
            || event.modifierFlags.contains(.control)

        if isRightClick {
            if isPresented { closeMenu() }
            appState.toggleActiveEQ()
            syncAnimationTimer()
            refreshIcon()
            setStatusItemHighlighted(false)
            return
        }

        pendingAnchorRect = statusItemScreenRect()
        if isPresented {
            closeMenu()
        } else {
            // Highlight immediately — mouseUp won’t clear it because we swallowed mouseDown.
            setStatusItemHighlighted(true)
            DispatchQueue.main.async { [weak self] in
                self?.openMenu()
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let chrome = PopoverChrome()
        menuChrome = chrome

        let root = MenuBarRoot(appState: appState, chrome: chrome)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        _ = hosting.view
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController = hosting

        let panel = StatusMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        // IMPORTANT: invalid combinations abort on modern macOS via _validateCollectionBehavior.
        // Do not mix .moveToActiveSpace with .canJoinAllSpaces.
        // Omit .canJoinAllSpaces so the panel doesn’t ride along when changing Spaces —
        // stock menu-bar menus dismiss instead.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]

        let frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 280)
        if #available(macOS 26.0, *) {
            // Stock Wi‑Fi / Sound use Liquid Glass on macOS 26+.
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = MenuMetrics.cornerRadius
            glass.style = .regular
            glass.clipsToBounds = true
            glass.autoresizingMask = [.width, .height]
            glass.contentView = hosting.view
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.clipsToBounds = true
            effect.maskImage = Self.roundedMaskImage(cornerRadius: MenuMetrics.cornerRadius)
            effect.autoresizingMask = [.width, .height]
            hosting.view.frame = effect.bounds
            hosting.view.autoresizingMask = [.width, .height]
            effect.addSubview(hosting.view)
            panel.contentView = effect
        }

        panel.alphaValue = 0
        panel.orderOut(nil)
        self.panel = panel
        chrome.attach(panel)
    }

    /// Stretchable rounded-rect mask for NSVisualEffectView (pre–macOS 26 fallback).
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let side = cornerRadius * 2 + 1
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Icon

    private func syncAnimationTimer() {
        if appState.isEQEngaged {
            guard animationTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tickAnimation()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            displayedLevel = 0
            animPhase = 0
        }
    }

    private func tickAnimation() {
        guard appState.isEQEngaged else {
            syncAnimationTimer()
            refreshIcon()
            return
        }
        let raw = CGFloat(appState.audioEngine.outputLevel)
        displayedLevel += (raw - displayedLevel) * 0.35
        if displayedLevel < 0.01 { displayedLevel = 0 }
        animPhase += 0.12 + displayedLevel * 0.55
        refreshIcon()
    }

    func refreshIcon() {
        let button = statusItem?.button
        let appearance = menuBarAppearance(for: button)
        let level = appState.isEQEngaged ? displayedLevel : 0
        button?.image = StatusIconImage.make(
            color: nsColor(from: appState.activeProfileColor),
            isEngaged: appState.isEQEngaged,
            appearance: appearance,
            level: level,
            phase: animPhase
        )
        // Image updates can wipe highlight drawing — re-assert while menu is open.
        if isPresented {
            setStatusItemHighlighted(true)
        }
    }

    private func menuBarAppearance(for button: NSStatusBarButton?) -> NSAppearance {
        let buttonAppearance = button?.effectiveAppearance
        let appAppearance = NSApp.effectiveAppearance
        if let buttonAppearance, StatusIconImage.isDark(buttonAppearance) {
            return buttonAppearance
        }
        if StatusIconImage.isDark(appAppearance) {
            return appAppearance
        }
        return buttonAppearance ?? appAppearance
    }

    // MARK: - Present / dismiss

    private func openMenu() {
        guard !isPresented else { return }
        ensurePanel()
        guard let panel, let hosting = hostingController else { return }

        appState.refreshAll()
        appState.restoreEngineIfNeeded()

        hosting.view.layoutSubtreeIfNeeded()
        let height = measuredContentHeight()
        menuChrome?.noteAppliedHeight(height)

        let size = NSSize(width: MenuMetrics.width, height: height)
        let frame = anchoredFrame(for: size, preferredAnchor: pendingAnchorRect)
        pendingAnchorRect = nil

        panel.setFrame(frame, display: true)

        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        isPresented = true
        setStatusItemHighlighted(true)

        menuChrome?.notePopoverDidShow()
        startDismissMonitors()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            self.menuChrome?.syncToMeasuredHeight()
            if let panel = self.panel {
                panel.setFrame(self.anchoredFrame(for: panel.frame.size, preferredAnchor: nil), display: true)
                panel.invalidateShadow()
            }
            self.setStatusItemHighlighted(true)
        }
    }

    private func closeMenu() {
        guard isPresented else { return }
        stopDismissMonitors()
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        isPresented = false
        setStatusItemHighlighted(false)
    }

    private func measuredContentHeight() -> CGFloat {
        guard let hosting = hostingController else { return 280 }
        let fitted = hosting.sizeThatFits(in: NSSize(width: MenuMetrics.width, height: 10_000))
        let fitting = hosting.view.fittingSize.height
        return max(120, ceil(max(fitted.height, fitting)))
    }

    private func anchoredFrame(for size: NSSize, preferredAnchor: NSRect?) -> NSRect {
        let margin = MenuMetrics.screenMargin
        let gap = MenuMetrics.menuBarGap
        let anchor = preferredAnchor ?? statusItemScreenRect()

        guard let anchor else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(
                x: visible.maxX - size.width - margin,
                y: visible.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? statusItem?.button?.window?.screen
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        var x = anchor.minX
        if x + size.width > visible.maxX - margin {
            x = anchor.maxX - size.width
        }
        x = min(max(x, visible.minX + margin), max(visible.minX + margin, visible.maxX - size.width - margin))
        // Leave a small gap under the menu bar, matching Wi‑Fi / Control Center.
        let y = anchor.minY - size.height - gap
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func statusItemScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        if screenRect.width > 0, screenRect.height > 0 {
            return screenRect
        }
        return window.frame
    }

    private func setStatusItemHighlighted(_ highlighted: Bool) {
        statusItem?.button?.highlight(highlighted)
    }

    // MARK: - Dismiss monitors

    private func startDismissMonitors() {
        stopDismissMonitors()

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isPresented else { return }
            if self.isMouseInStatusItem() { return }
            self.closeMenu()
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isPresented else { return event }
            if event.type == .keyDown {
                // Esc — same as stock menu-bar menus.
                if event.keyCode == 53 {
                    self.closeMenu()
                    return nil
                }
                return event
            }
            if self.isEventInsideMenu(event) { return event }
            // Status-item clicks are handled (and swallowed) by statusItemClickMonitor.
            if event.window === self.statusItem?.button?.window { return event }
            self.closeMenu()
            return event
        }
    }

    private func stopDismissMonitors() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

    private func isEventInsideMenu(_ event: NSEvent) -> Bool {
        guard let panel, isPresented else { return false }
        if event.window === panel { return true }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func isMouseInStatusItem() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let mouse = NSEvent.mouseLocation
        if window.frame.contains(mouse) { return true }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return screenRect.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    private func nsColor(from color: Color) -> NSColor {
        NSColor(color)
    }
}

final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Kill the WindowServer hairline that contours `hasShadow` on transparent panels.
    /// Stock Control Center menus suppress this rim; without it we get a gray outline.
    @objc(_shadowRimInfo)
    func shadowRimInfo() -> [String: NSNumber] {
        ["kCUIMeasureWindowFrameRimDensity": 0]
    }
}

enum StatusIconImage {
    static func make(
        color: NSColor,
        isEngaged: Bool,
        appearance: NSAppearance? = nil,
        level: CGFloat = 0,
        phase: CGFloat = 0,
        size: CGFloat = 18
    ) -> NSImage {
        let sizeValue = NSSize(width: size, height: size)
        let image = NSImage(size: sizeValue)
        image.lockFocus()

        let inset: CGFloat = 1.0
        let drawRect = NSRect(origin: .zero, size: sizeValue).insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: drawRect.midX, y: drawRect.midY)
        let radius = min(drawRect.width, drawRect.height) / 2 * 0.92

        let darkBar = isDark(appearance ?? NSApp.effectiveAppearance)
        let paint: NSColor = isEngaged
            ? contrastAdjusted(color, againstDarkBackground: darkBar)
            : .black

        let blob = EQBlob.bezierPath(center: center, radius: radius, level: level, phase: phase)

        if isEngaged {
            let halo = darkBar
                ? NSColor.white.withAlphaComponent(0.50)
                : NSColor.black.withAlphaComponent(0.50)
            halo.set()
            blob.lineWidth = 2.6
            blob.stroke()
        }

        paint.set()
        blob.fill()

        image.unlockFocus()
        image.isTemplate = !isEngaged
        return image
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func contrastAdjusted(_ color: NSColor, againstDarkBackground: Bool) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        if againstDarkBackground {
            b = max(b, 0.78)
            s = min(1.0, max(s, 0.55))
        } else {
            b = min(b, 0.72)
            if b > 0.9 { b = 0.62 }
            s = min(1.0, max(s, 0.45))
        }
        return NSColor(hue: h, saturation: s, brightness: b, alpha: a)
    }
}

private enum MenuMetrics {
    static let width: CGFloat = 320
    /// Control Center / Wi‑Fi panels use 16; default windows use 10.
    static let cornerRadius: CGFloat = 16
    static let minMeasuredHeight: CGFloat = 80
    static let screenMargin: CGFloat = 8
    /// Gap between menu-bar bottom and panel top (matches system extras).
    static let menuBarGap: CGFloat = 5
}

@MainActor
final class PopoverChrome: ObservableObject {
    static let disclosureDuration: TimeInterval = 0.28

    @Published private(set) var presentationID: Int = 0

    private weak var panel: StatusMenuPanel?
    private var panelIsShowing: () -> Bool = { false }
    private(set) var isDisclosureAnimating = false
    private var measuredHeight: CGFloat = 0

    func attach(_ panel: StatusMenuPanel) {
        self.panel = panel
        self.panelIsShowing = { [weak panel] in
            (panel?.alphaValue ?? 0) > 0.5 && (panel?.isVisible == true)
        }
    }

    func notePopoverDidShow() {
        presentationID += 1
    }

    func reportMeasuredHeight(_ height: CGFloat) {
        let h = ceil(height)
        guard h >= MenuMetrics.minMeasuredHeight else { return }
        measuredHeight = h
        guard !isDisclosureAnimating else { return }
        guard panelIsShowing() else { return }
        applyHeight(h, animated: false)
    }

    func syncToMeasuredHeight() {
        guard measuredHeight >= MenuMetrics.minMeasuredHeight else { return }
        applyHeight(measuredHeight, animated: false)
    }

    func noteAppliedHeight(_ height: CGFloat) {
        measuredHeight = max(MenuMetrics.minMeasuredHeight, ceil(height))
    }

    /// Animates the panel frame via AppKit’s animator (compositor-driven).
    /// Pair with `withAnimation(.easeInOut(duration: disclosureDuration))` on content progress
    /// so list height and window height share the same curve without a CPU tick loop.
    func animateDisclosure(deltaHeight: CGFloat) {
        guard let panel, abs(deltaHeight) > 0.5 else { return }

        isDisclosureAnimating = true

        var frame = panel.frame
        let newHeight = max(1, frame.height + deltaHeight)
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        frame.size.width = MenuMetrics.width

        let hadShadow = panel.hasShadow
        if hadShadow {
            panel.hasShadow = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.disclosureDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if hadShadow {
                    self.panel?.hasShadow = true
                    self.panel?.invalidateShadow()
                }
                self.isDisclosureAnimating = false
                self.syncToMeasuredHeight()
            }
        })
    }

    private func applyHeight(_ height: CGFloat, animated: Bool) {
        guard let panel else { return }
        let newHeight = max(1, height)
        var frame = panel.frame
        guard abs(frame.height - newHeight) > 0.25 || abs(frame.width - MenuMetrics.width) > 0.25 else {
            return
        }
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        frame.size.width = MenuMetrics.width
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.disclosureDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var chrome: PopoverChrome

    var body: some View {
        MenuBarView()
            .environmentObject(appState)
            .environmentObject(chrome)
            .frame(width: MenuMetrics.width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            // Glass / vibrancy lives on the AppKit content root.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ViewHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ViewHeightKey.self) { height in
                chrome.reportMeasuredHeight(height)
            }
    }
}
