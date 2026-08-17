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
        hosting.preferredContentSize = NSSize(width: MenuMetrics.width, height: MenuMetrics.hostingHeight)
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
        // Finder → menu drops (EQ profile import).
        panel.registerForDraggedTypes([.fileURL])
        // IMPORTANT: invalid combinations abort on modern macOS via _validateCollectionBehavior.
        // Do not mix .moveToActiveSpace with .canJoinAllSpaces.
        // Omit .canJoinAllSpaces so the panel doesn’t ride along when changing Spaces —
        // stock menu-bar menus dismiss instead.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]

        let frame = NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 280)

        // Fixed tall hosting view, top-pinned via autoresizing. Never set its frame
        // while the panel animates — that fights Core Animation and makes the menu slide.
        // SwiftUI content top-aligns inside this box; the panel clips the rest.
        let contentRoot = NSView(frame: frame)
        contentRoot.autoresizingMask = [.width, .height]
        hosting.view.frame = NSRect(
            x: 0,
            y: frame.height - MenuMetrics.hostingHeight,
            width: frame.width,
            height: MenuMetrics.hostingHeight
        )
        hosting.view.autoresizingMask = [.width, .minYMargin]
        contentRoot.addSubview(hosting.view)

        if #available(macOS 26.0, *) {
            // Stock Wi‑Fi / Sound use Liquid Glass on macOS 26+.
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = MenuMetrics.cornerRadius
            glass.style = .regular
            glass.clipsToBounds = true
            glass.autoresizingMask = [.width, .height]
            glass.contentView = contentRoot
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.clipsToBounds = true
            effect.maskImage = Self.roundedMaskImage(cornerRadius: MenuMetrics.cornerRadius)
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(contentRoot)
            panel.contentView = effect
        }

        panel.minSize = NSSize(width: MenuMetrics.width, height: MenuMetrics.minMeasuredHeight)
        panel.maxSize = NSSize(width: MenuMetrics.width, height: MenuMetrics.hostingHeight)
        panel.contentMinSize = NSSize(width: MenuMetrics.width, height: MenuMetrics.minMeasuredHeight)
        panel.contentMaxSize = NSSize(width: MenuMetrics.width, height: MenuMetrics.hostingHeight)
        // Implicit window animations will interpolate to SwiftUI’s fitting size (sometimes 0).
        // Height changes go through PopoverChrome’s explicit NSAnimationContext instead.
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.orderOut(nil)
        self.panel = panel
        chrome.attach(panel) { [weak self] size in
            self?.anchoredFrame(for: size, preferredAnchor: nil)
                ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
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
        let shouldAnimate = appState.isEQEngaged && appState.config.animatedMenuBarIcon
        if shouldAnimate {
            guard animationTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / EQBlob.animationFrameRate, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tickAnimation()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            EQBlobMotion.shared.reset()
        }
    }

    private func tickAnimation() {
        guard appState.isEQEngaged, appState.config.animatedMenuBarIcon else {
            syncAnimationTimer()
            refreshIcon()
            return
        }
        EQBlobMotion.shared.tick(rawLevel: CGFloat(appState.audioEngine.outputLevel))
        refreshIcon()
    }

    func refreshIcon() {
        let button = statusItem?.button
        let appearance = menuBarAppearance(for: button)
        let animate = appState.isEQEngaged && appState.config.animatedMenuBarIcon
        let motion = EQBlobMotion.shared
        button?.image = StatusIconImage.make(
            color: nsColor(from: appState.activeProfileColor),
            isEngaged: appState.isEQEngaged,
            appearance: appearance,
            level: animate ? motion.level : 0,
            phase: animate ? motion.phase : 0
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
        // Menu open is often the first chance to notice a Settings grant (accessory apps
        // don’t always get a clean didBecomeActive when returning from System Settings).
        appState.retryAudioEngine()

        // Laying out publishes the content height through the chrome; the root view is
        // greedy by design, so its fitting size would just be the proposal.
        hosting.view.layoutSubtreeIfNeeded()
        let height = menuChrome?.contentHeight ?? MenuMetrics.fallbackHeight

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

    /// Public so Settings (and similar) can dismiss the menu without going through a modal hook.
    func dismissMenu() {
        closeMenu()
    }

    private func closeMenu() {
        guard isPresented else { return }
        stopDismissMonitors()
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        isPresented = false
        setStatusItemHighlighted(false)
        appState.cancelProfileEditor()
        menuChrome?.resetToHome()
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

        // Mouse-up (not down) so a Finder drag can enter the panel — mouse-down
        // outside would dismiss before dropDestination runs.
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            guard let self, self.isPresented else { return }
            if self.isMouseInStatusItem() { return }
            if self.isMouseOverMenuChrome() { return }
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
        guard isPresented else { return false }
        if let window = event.window, isMenuOwnedWindow(window) {
            return true
        }
        return isMouseOverMenuChrome()
    }

    /// Panel plus popovers presented from it (color picker). SwiftUI `.popover` is a
    /// separate window and often hangs past the panel edge — those clicks must not
    /// count as “outside” or the menu dismisses before the swatch receives the event.
    private func isMenuOwnedWindow(_ window: NSWindow) -> Bool {
        if window === panel { return true }
        if window === statusItem?.button?.window { return false }

        var ancestor: NSWindow? = window
        while let current = ancestor {
            if current === panel { return true }
            ancestor = current.parent
        }

        // SwiftUI popovers frequently omit a parent link to the presenting panel.
        let typeName = String(describing: type(of: window))
        if typeName.localizedCaseInsensitiveContains("popover") { return true }
        if window.level == .popUpMenu { return true }
        return false
    }

    private func isMouseOverMenuChrome() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let panel, panel.frame.contains(mouse) { return true }
        return NSApp.windows.contains { window in
            window.isVisible && isMenuOwnedWindow(window) && window.frame.contains(mouse)
        }
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
        // Leave room for ring stroke so the animated edge isn’t clipped.
        let radius = min(drawRect.width, drawRect.height) / 2 * 0.78

        let darkBar = isDark(appearance ?? NSApp.effectiveAppearance)
        let paint: NSColor = isEngaged
            ? contrastAdjusted(color, againstDarkBackground: darkBar)
            : .black

        let ring = EQBlob.bezierPath(center: center, radius: radius, level: level, phase: phase)
        let ringWidth = EQBlob.ringLineWidth(outerRadius: radius)
        let inner = NSBezierPath(ovalIn: EQBlob.innerCircleRect(center: center, outerRadius: radius))

        paint.set()
        inner.fill()
        ring.lineWidth = ringWidth
        ring.stroke()

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
    /// Only used before SwiftUI has ever reported a height.
    static let fallbackHeight: CGFloat = 280
    /// Fixed hosting-view height: tall enough for any menu, so the view never needs
    /// resizing while the panel animates. Overflow is clipped by the panel.
    static let hostingHeight: CGFloat = 1600
    static let screenMargin: CGFloat = 8
    /// Gap between menu-bar bottom and panel top (matches system extras).
    static let menuBarGap: CGFloat = 5
}

/// Full-panel destinations that replace the core menu in the same window.
enum MenuPanelScreen: Hashable {
    case home
    case settings
    case eqEditor
}

@MainActor
final class PopoverChrome: ObservableObject {
    static let disclosureDuration: TimeInterval = 0.28

    @Published private(set) var presentationID: Int = 0
    /// Which full-panel screen is showing. Swap in-place instead of opening a second window.
    @Published private(set) var presentedScreen: MenuPanelScreen = .home

    private weak var panel: StatusMenuPanel?
    private var panelIsShowing: () -> Bool = { false }
    private var anchoredFrame: ((NSSize) -> NSRect)?
    private var measuredHeight: CGFloat = 0
    private var heightByScreen: [MenuPanelScreen: CGFloat] = [:]
    private var expectsAnimatedHeight = false
    /// While SwiftUI swaps screens, refuse shrinks so a 0-fitting-size frame can’t collapse the panel.
    private var lockHeight = false

    func attach(_ panel: StatusMenuPanel, anchoredFrame: @escaping (NSSize) -> NSRect) {
        self.panel = panel
        self.anchoredFrame = anchoredFrame
        self.panelIsShowing = { [weak panel] in
            (panel?.alphaValue ?? 0) > 0.5 && (panel?.isVisible == true)
        }
    }

    func notePopoverDidShow() {
        presentationID += 1
    }

    /// Replace the core menu with another full-panel screen (Settings, later PEQ editor).
    func present(_ screen: MenuPanelScreen) {
        swapScreen(screen)
    }

    func dismissToHome() {
        swapScreen(.home)
    }

    /// Instant content swap (the home menu stays mounted so it isn’t remade at Settings’
    /// height). Height is locked across the swap so AppKit can’t collapse the panel to a
    /// sliver while the incoming screen’s fitting size is still 0, then one window
    /// animation runs after layout.
    private func swapScreen(_ screen: MenuPanelScreen) {
        guard presentedScreen != screen else { return }
        lockHeight = true
        freezePanelHeight()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withTransaction(transaction) {
                presentedScreen = screen
            }
        }

        expectsAnimatedHeight = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockHeight = false
            guard let height = self.heightByScreen[screen],
                  height >= MenuMetrics.minMeasuredHeight,
                  self.panelIsShowing()
            else { return }
            self.measuredHeight = height
            self.expectsAnimatedHeight = false
            self.animateHeight(to: height)
        }
    }

    /// Pin minSize to a known-good height so implicit resizes cannot collapse us to a sliver.
    private func freezePanelHeight() {
        guard let panel, panelIsShowing() else { return }
        let floor = max(
            panel.frame.height,
            measuredHeight,
            heightByScreen[.home] ?? 0,
            heightByScreen[presentedScreen] ?? 0,
            MenuMetrics.minMeasuredHeight
        )
        let size = NSSize(width: MenuMetrics.width, height: floor)
        panel.minSize = size
        panel.contentMinSize = size
    }

    private func restoreHeightFloor() {
        guard let panel else { return }
        let size = NSSize(width: MenuMetrics.width, height: MenuMetrics.minMeasuredHeight)
        panel.minSize = size
        panel.contentMinSize = size
    }

    /// Instant reset when the menu closes so the next open is the core UI.
    func resetToHome() {
        lockHeight = false
        restoreHeightFloor()
        presentedScreen = .home
        if let home = heightByScreen[.home], home >= MenuMetrics.minMeasuredHeight {
            measuredHeight = home
        }
    }

    /// Runs `changes` in the disclosure animation. The panel is resized by a single
    /// Core Animation window animation rather than a new frame every tick: the window
    /// server interpolates that smoothly, while per-frame `setFrame` calls get composited
    /// a frame or two late and leave the panel edges jittering.
    func animatingDisclosure(_ changes: () -> Void) {
        expectsAnimatedHeight = true
        withAnimation(.easeInOut(duration: Self.disclosureDuration)) {
            changes()
        }
        // Nothing to animate to if the layout height did not actually change.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.disclosureDuration + 0.1))
            self?.expectsAnimatedHeight = false
        }
    }

    /// SwiftUI publishes its laid-out height once per change, at the start of the
    /// animation, so this is where the matching window animation is kicked off.
    func reportMeasuredHeight(_ height: CGFloat, for screen: MenuPanelScreen) {
        let h = ceil(height)
        guard h >= MenuMetrics.minMeasuredHeight else { return }
        heightByScreen[screen] = h
        guard screen == presentedScreen else { return }
        measuredHeight = h
        guard panelIsShowing(), !lockHeight else { return }

        if expectsAnimatedHeight {
            expectsAnimatedHeight = false
            animateHeight(to: h)
        } else {
            applyHeight(h)
        }
    }

    func syncToMeasuredHeight() {
        let height = heightByScreen[presentedScreen] ?? measuredHeight
        guard height >= MenuMetrics.minMeasuredHeight else { return }
        applyHeight(height)
    }

    /// Content height as SwiftUI last laid it out. The root view is deliberately greedy
    /// so it top-aligns in the fixed hosting view, which makes `sizeThatFits` useless.
    var contentHeight: CGFloat? {
        let height = heightByScreen[presentedScreen] ?? measuredHeight
        return height >= MenuMetrics.minMeasuredHeight ? height : nil
    }

    /// Hands the whole resize to Core Animation in one go, on the same curve and duration
    /// the SwiftUI content is using, so the two stay in step without a per-frame driver.
    private func animateHeight(to height: CGFloat) {
        let height = max(MenuMetrics.minMeasuredHeight, height)
        guard panelIsShowing(), let panel, let frame = topPinnedFrame(for: height) else { return }
        restoreHeightFloor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.disclosureDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak panel] in
            Task { @MainActor in
                panel?.invalidateShadow()
            }
        }
    }

    /// Instant / structural resizes re-pin under the status item so a drifted top edge
    /// can’t accumulate (e.g. menu open while Settings flips Custom EQ per device).
    private func applyHeight(_ height: CGFloat) {
        let height = max(MenuMetrics.minMeasuredHeight, height)
        guard panelIsShowing(), let panel else { return }
        let size = NSSize(width: MenuMetrics.width, height: height)
        guard abs(panel.frame.height - size.height) > 0.25
            || abs(panel.frame.width - size.width) > 0.25
        else { return }
        restoreHeightFloor()
        let frame = anchoredFrame?(size) ?? topPinnedFrame(for: size.height) ?? panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    /// Grow/shrink downward from the current top edge (disclosure animation).
    private func topPinnedFrame(for height: CGFloat) -> NSRect? {
        guard let panel else { return nil }
        let newHeight = max(MenuMetrics.minMeasuredHeight, height)
        var frame = panel.frame
        guard abs(frame.height - newHeight) > 0.25 || abs(frame.width - MenuMetrics.width) > 0.25 else {
            return nil
        }
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        frame.size.width = MenuMetrics.width
        return frame
    }

}

private struct MeasuredScreen<Content: View>: View {
    let screen: MenuPanelScreen
    @ObservedObject var chrome: PopoverChrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                chrome.reportMeasuredHeight(height, for: screen)
            }
    }
}

private struct MenuBarRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var chrome: PopoverChrome

    private var isHome: Bool { chrome.presentedScreen == .home }

    var body: some View {
        MeasuredScreen(screen: .home, chrome: chrome) {
            MenuBarView()
        }
            .opacity(isHome ? 1 : 0)
            .allowsHitTesting(isHome)
            .accessibilityHidden(!isHome)
            .overlay(alignment: .top) {
                if chrome.presentedScreen == .settings {
                    MeasuredScreen(screen: .settings, chrome: chrome) {
                        SettingsView(appState: appState)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                } else if chrome.presentedScreen == .eqEditor {
                    MeasuredScreen(screen: .eqEditor, chrome: chrome) {
                        ProfileEditorView(appState: appState)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .environmentObject(appState)
            .environmentObject(chrome)
            .frame(width: MenuMetrics.width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            // Permission banner can appear while a system sheet is up; re-sync after layout
            // settles so the panel grows instead of clipping.
            .onChange(of: appState.needsAudioPermission) { _, _ in
                DispatchQueue.main.async {
                    chrome.syncToMeasuredHeight()
                }
            }
            // Top-align within the fixed-height hosting view. This makes the root greedy,
            // so the panel's height comes from the measurement above, never from asking
            // the hosting controller what size it wants.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
