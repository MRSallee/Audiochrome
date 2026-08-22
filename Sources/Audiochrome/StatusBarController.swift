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
    /// Kept for the life of the open menu — later layout passes must not
    /// re-query a nil/stale button window and dump the panel in a screen corner.
    private var lastAnchorRect: NSRect?

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

        rememberAnchorRect()
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

        // Fixed tall hosting view, top-pinned in layout so it follows window
        // resize (including animator().setFrame) without mutating glass.
        let contentRoot = TopPinnedHostView(frame: frame)
        contentRoot.autoresizingMask = [.width, .height]
        contentRoot.hostingHeight = MenuMetrics.hostingHeight
        hosting.view.frame = NSRect(
            x: 0,
            y: frame.height - MenuMetrics.hostingHeight,
            width: frame.width,
            height: MenuMetrics.hostingHeight
        )
        hosting.view.autoresizingMask = []
        contentRoot.addSubview(hosting.view)
        contentRoot.hostingView = hosting.view
        panel.hostView = contentRoot

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
        panel.pinHostingToTop()
        self.panel = panel
        chrome.attach(panel) { [weak self] size in
            self?.anchoredFrame(for: size)
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
        let animate = appState.isEQEngaged && appState.config.animatedMenuBarIcon
        let motion = EQBlobMotion.shared
        let hex = appState.activeProfileColorHex
        // Engaged icon sits on a white plate — match in-app mark (`.ui` light), not the
        // pale menuBarDark ramp meant for drawing directly on a dark menu bar.
        let paint = hex.map { ProfileColorPalette.nsColor($0, role: .ui, dark: false) }
        button?.image = StatusIconImage.make(
            color: paint ?? .black,
            isEngaged: appState.isEQEngaged,
            discRadius: animate ? motion.discRadius : 6,
            animated: animate
        )
        // Image updates can wipe highlight drawing — re-assert while menu is open.
        if isPresented {
            setStatusItemHighlighted(true)
        }
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

        // New panels ignore setFrame until they’re on a screen. Show first, then place.
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.setFrame(anchoredFrame(for: size), display: true)
        panel.pinHostingToTop()
        panel.invalidateShadow()
        isPresented = true
        setStatusItemHighlighted(true)

        menuChrome?.notePopoverDidShow()
        startDismissMonitors()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, let panel = self.panel else { return }
            // Status-item window.frame is often only correct after the first show.
            self.rememberAnchorRect()
            self.menuChrome?.syncToMeasuredHeight()
            let height = self.menuChrome?.contentHeight ?? panel.frame.height
            panel.setFrame(
                self.anchoredFrame(for: NSSize(width: MenuMetrics.width, height: height)),
                display: true
            )
            panel.pinHostingToTop()
            panel.invalidateShadow()
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
        menuChrome?.persistOnHide()
    }

    private func rememberAnchorRect() {
        if let rect = statusItemScreenRect(), rect.width > 0, rect.height > 0 {
            lastAnchorRect = rect
        }
    }

    private func anchoredFrame(for size: NSSize) -> NSRect {
        let margin = MenuMetrics.screenMargin
        let gap = MenuMetrics.menuBarGap
        let anchor = lastAnchorRect ?? statusItemScreenRect()

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

        // Native menu-bar extras trailing-align: panel.maxX == status-item highlight.maxX.
        var x = anchor.maxX - size.width
        if x < visible.minX + margin {
            x = visible.minX + margin
        }
        if x + size.width > visible.maxX - margin {
            x = visible.maxX - size.width - margin
        }
        // Leave a small gap under the menu bar, matching Wi‑Fi / Control Center.
        let y = anchor.minY - size.height - gap
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func statusItemScreenRect() -> NSRect? {
        guard let button = statusItem?.button else { return nil }
        // The status-item window *is* the highlight slot. Prefer it over converting
        // button.bounds, which can lag after activate / highlight.
        if let window = button.window {
            let slot = window.frame
            if slot.width > 0, slot.height > 0 {
                return slot
            }
        }
        return nil
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
}

/// Pins the tall SwiftUI host to the top of the panel’s content as bounds change.
/// Safe during `animator().setFrame` — only touches the host, never glass.
final class TopPinnedHostView: NSView {
    var hostingView: NSView?
    var hostingHeight: CGFloat = 1600

    override func layout() {
        super.layout()
        guard let hostingView else { return }
        let next = NSRect(
            x: 0,
            y: bounds.height - hostingHeight,
            width: bounds.width,
            height: hostingHeight
        )
        if hostingView.frame != next {
            hostingView.frame = next
        }
    }
}

final class StatusMenuPanel: NSPanel {
    var hostView: TopPinnedHostView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func pinHostingToTop() {
        hostView?.needsLayout = true
        hostView?.layoutSubtreeIfNeeded()
    }

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
        discRadius: CGFloat = 6,
        animated: Bool = false,
        size: CGFloat = 18
    ) -> NSImage {
        let sizeValue = NSSize(width: size, height: size)
        let image = NSImage(size: sizeValue)
        image.lockFocus()

        let inset: CGFloat = 0.5
        let plateRect = NSRect(origin: .zero, size: sizeValue).insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: plateRect.midX, y: plateRect.midY)
        // Match in-app mark: 12pt disc at rest inside 18pt plate.
        let restRadius: CGFloat = 6

        if isEngaged {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: plateRect).fill()

            let radius = animated ? max(1, discRadius) : restRadius
            color.setFill()
            Self.fillCircle(center: center, radius: radius)
        } else {
            // Template disc — system tints for the menu bar.
            NSColor.black.setFill()
            Self.fillCircle(center: center, radius: restRadius)
        }

        image.unlockFocus()
        image.isTemplate = !isEngaged
        return image
    }

    private static func fillCircle(center: CGPoint, radius: CGFloat) {
        let rect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        NSBezierPath(ovalIn: rect).fill()
    }
}

private enum MenuMetrics {
    static let width: CGFloat = 320
    /// Control Center / Wi‑Fi panels use 16; default windows use 10.
    static let cornerRadius: CGFloat = 16
    static let minMeasuredHeight: CGFloat = 80
    /// Only used before SwiftUI has ever reported a height. Tall enough for the
    /// no-permission home menu (CTA + other outputs + Settings + Quit + Relaunch).
    static let fallbackHeight: CGFloat = 480
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
    static let screenTransitionDuration: TimeInterval = 0.20

    @Published private(set) var presentationID: Int = 0
    /// Logical destination for height + chrome. Home stays mounted underneath.
    @Published private(set) var presentedScreen: MenuPanelScreen = .home
    /// Settings / editor overlay while sliding in or out. `nil` when fully home.
    @Published private(set) var mountedOverlay: MenuPanelScreen?
    /// 0 = off to the right (home visible), 1 = fully covering home.
    @Published private(set) var overlayProgress: CGFloat = 0

    private weak var panel: StatusMenuPanel?
    private var panelIsShowing: () -> Bool = { false }
    private var anchoredFrame: ((NSSize) -> NSRect)?
    private var measuredHeight: CGFloat = 0
    private var heightByScreen: [MenuPanelScreen: CGFloat] = [:]
    private var expectsAnimatedHeight = false
    private var pendingHeightDuration: TimeInterval = disclosureDuration
    /// While SwiftUI swaps screens, refuse shrinks so a 0-fitting-size frame can’t collapse the panel.
    private var lockHeight = false
    private var overlayUnmountTask: Task<Void, Never>?
    /// True while `animator().setFrame` is interpolating — `applyHeight` must not snap.
    private var heightAnimationInFlight = false

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

    /// Slide a full-panel screen in from the right over the core menu.
    func present(_ screen: MenuPanelScreen) {
        guard screen != .home else {
            dismissToHome()
            return
        }
        guard presentedScreen != screen else { return }
        overlayUnmountTask?.cancel()
        overlayUnmountTask = nil
        mountOverlay(screen, progress: mountedOverlay == screen ? overlayProgress : 0)
        presentedScreen = screen
        beginHeightTransition(duration: Self.screenTransitionDuration)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockHeight = false
            withAnimation(.easeInOut(duration: Self.screenTransitionDuration)) {
                self.overlayProgress = 1
            }
            self.kickHeightAnimation(for: screen)
        }
    }

    /// Slide the overlay back out and restore the core menu height.
    func dismissToHome() {
        guard presentedScreen != .home else { return }
        presentedScreen = .home
        beginHeightTransition(duration: Self.screenTransitionDuration)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockHeight = false
            withAnimation(.easeInOut(duration: Self.screenTransitionDuration)) {
                self.overlayProgress = 0
            }
            self.kickHeightAnimation(for: .home)
            self.scheduleOverlayUnmount()
        }
    }

    private func mountOverlay(_ screen: MenuPanelScreen, progress: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mountedOverlay = screen
            overlayProgress = progress
        }
    }

    private func beginHeightTransition(duration: TimeInterval) {
        lockHeight = true
        freezePanelHeight()
        expectsAnimatedHeight = true
        pendingHeightDuration = duration
    }

    private func kickHeightAnimation(for screen: MenuPanelScreen) {
        guard let height = heightByScreen[screen],
              height >= MenuMetrics.minMeasuredHeight,
              panelIsShowing()
        else { return }
        measuredHeight = height
        expectsAnimatedHeight = false
        animateHeight(to: height)
    }

    private func scheduleOverlayUnmount() {
        overlayUnmountTask?.cancel()
        overlayUnmountTask = Task { @MainActor [weak self] in
            let delay = PopoverChrome.screenTransitionDuration + 0.05
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.presentedScreen == .home, self.overlayProgress < 0.01 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.mountedOverlay = nil
            }
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

    /// Keep the current screen when the menu hides so the next open returns there.
    func persistOnHide() {
        overlayUnmountTask?.cancel()
        overlayUnmountTask = nil
        lockHeight = false
        restoreHeightFloor()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if presentedScreen == .home {
                overlayProgress = 0
                mountedOverlay = nil
            } else {
                overlayProgress = 1
                mountedOverlay = presentedScreen
            }
        }
        if let height = heightByScreen[presentedScreen], height >= MenuMetrics.minMeasuredHeight {
            measuredHeight = height
        }
    }

    /// Runs `changes` in the disclosure animation. The panel is resized by a single
    /// Core Animation window animation rather than a new frame every tick: the window
    /// server interpolates that smoothly, while per-frame `setFrame` calls get composited
    /// a frame or two late and leave the panel edges jittering.
    func animatingDisclosure(_ changes: () -> Void) {
        expectsAnimatedHeight = true
        pendingHeightDuration = Self.disclosureDuration
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
            applyHeight(h, reanchor: false)
        }
    }

    func syncToMeasuredHeight() {
        let height = heightByScreen[presentedScreen] ?? measuredHeight
        guard height >= MenuMetrics.minMeasuredHeight else { return }
        applyHeight(height, reanchor: true)
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
        heightAnimationInFlight = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = pendingHeightDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                self?.heightAnimationInFlight = false
                panel?.pinHostingToTop()
                panel?.invalidateShadow()
            }
        }
    }

    /// Instant / structural resizes. Measuring reports keep the current top edge
    /// (`reanchor: false`) so they cannot cancel an in-flight height animation.
    /// Open / permission sync may re-pin under the status item.
    private func applyHeight(_ height: CGFloat, reanchor: Bool) {
        let height = max(MenuMetrics.minMeasuredHeight, height)
        guard panelIsShowing(), let panel, !heightAnimationInFlight else { return }
        let size = NSSize(width: MenuMetrics.width, height: height)
        let frame: NSRect
        if reanchor {
            frame = anchoredFrame?(size) ?? topPinnedFrame(for: size.height) ?? panel.frame
        } else if let pinned = topPinnedFrame(for: size.height) {
            frame = pinned
        } else {
            return
        }
        guard abs(panel.frame.height - frame.height) > 0.25
            || abs(panel.frame.width - frame.width) > 0.25
            || (reanchor && (
                abs(panel.frame.origin.x - frame.origin.x) > 0.25
                || abs(panel.frame.origin.y - frame.origin.y) > 0.25
            ))
        else { return }
        restoreHeightFloor()
        panel.setFrame(frame, display: true)
        panel.pinHostingToTop()
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

private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Measures SwiftUI’s laid-out height via PreferenceKey (same path as v0.9 / v1.0).
/// Width must be applied *inside* the fixedSize+GeometryReader pair — measuring
/// unconstrained then framing outside was under-reporting and clipping the footer.
private struct MeasuredScreen<Content: View>: View {
    let screen: MenuPanelScreen
    @ObservedObject var chrome: PopoverChrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: MenuMetrics.width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ViewHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ViewHeightKey.self) { height in
                chrome.reportMeasuredHeight(height, for: screen)
            }
    }
}

private struct MenuBarRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var chrome: PopoverChrome
    @Environment(\.colorScheme) private var colorScheme

    private var homeIsInteractive: Bool { chrome.overlayProgress < 0.98 }

    var body: some View {
        MeasuredScreen(screen: .home, chrome: chrome) {
            MenuBarView()
        }
            .overlay {
                Rectangle()
                    .fill(Color.black.opacity(0.32 * chrome.overlayProgress))
                    .allowsHitTesting(chrome.overlayProgress > 0.02)
            }
            .allowsHitTesting(homeIsInteractive)
            .accessibilityHidden(!homeIsInteractive)
            .overlay(alignment: .topLeading) {
                slidingOverlay
            }
            .environmentObject(appState)
            .environmentObject(chrome)
            .background {
                EndEditingClickMonitor()
            }
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

    @ViewBuilder
    private var slidingOverlay: some View {
        if let screen = chrome.mountedOverlay, screen != .home {
            MeasuredScreen(screen: screen, chrome: chrome) {
                overlayScreen(screen)
                    .background { overlayVeil }
            }
            .offset(x: (1 - chrome.overlayProgress) * MenuMetrics.width)
            .allowsHitTesting(chrome.overlayProgress > 0.02)
            .accessibilityHidden(chrome.overlayProgress < 0.5)
        }
    }

    @ViewBuilder
    private func overlayScreen(_ screen: MenuPanelScreen) -> some View {
        switch screen {
        case .home:
            EmptyView()
        case .settings:
            SettingsView(appState: appState)
        case .eqEditor:
            ProfileEditorView(appState: appState)
        }
    }

    private var overlayVeil: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Rectangle().fill(
                    colorScheme == .dark
                        ? Color.black.opacity(0.18)
                        : Color.white.opacity(0.42)
                )
            }
    }
}
