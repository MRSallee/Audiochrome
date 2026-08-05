import AppKit
import AudiochromeCore
import Combine
import SwiftUI

/// AppKit status item — more reliable than SwiftUI MenuBarExtra for SPM-built apps.
@MainActor
final class StatusBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<MenuBarRoot>?
    private var popoverChrome: PopoverChrome?
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var animationTimer: Timer?
    private var animPhase: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setup()
    }

    private func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.appearsDisabled = false
            button.toolTip = "Audiochrome"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // mouseDown avoids the classic transient race: mouseDown auto-closes,
            // then mouseUp’s action re-opens (click appears to do nothing).
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])

            // At create time effectiveAppearance is often still the default (light),
            // so the halo picks the wrong color until the button joins the menu bar.
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshIcon()
                }
            }
        }

        let popover = NSPopover()
        // We dismiss ourselves (monitors + status-item toggle). `.transient` auto-closes
        // on status-item mouseDown and races the toggle action.
        popover.behavior = .applicationDefined
        // Keep AppKit's show/hide animation off — we drive height ourselves so it
        // can match the SwiftUI disclosure curve (HTML/CSS-style height transition).
        popover.animates = false
        popover.delegate = self

        let chrome = PopoverChrome()
        chrome.attach(popover)
        self.popoverChrome = chrome

        let root = MenuBarRoot(appState: appState, chrome: chrome)
        let hosting = NSHostingController(rootView: root)
        // Don't let intrinsic-size chasing snap to the animation's end value.
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: 280)
        self.popover = popover
        self.hostingController = hosting

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

        // Defer past status-item attachment so the first paint sees the real menu-bar appearance.
        DispatchQueue.main.async { [weak self] in
            self?.syncAnimationTimer()
            self?.refreshIcon()
            DispatchQueue.main.async { [weak self] in
                self?.refreshIcon()
            }
        }
    }

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
        // Display smoothing so the blob eases instead of stuttering with meter hops.
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
        let tip: String
        if appState.needsAudioPermission {
            tip = "Audiochrome — needs system audio access\nOpen the menu to fix"
        } else if appState.isEQEngaged, let name = appState.activeMapping?.profileFilename {
            tip = "Audiochrome — \((name as NSString).deletingPathExtension)\nRight-click to toggle EQ"
        } else {
            tip = "Audiochrome — EQ off\nRight-click to toggle EQ"
        }
        button?.toolTip = tip
    }

    /// Status items briefly report a light default appearance before attaching to the menu bar.
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

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseDown {
            toggleEQFromStatusItem()
            return
        }
        togglePopover(sender)
    }

    private func toggleEQFromStatusItem() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        }
        appState.toggleActiveEQ()
        syncAnimationTimer()
        refreshIcon()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            appState.refreshAll()
            appState.restoreEngineIfNeeded()
            // Size to content *before* show — a 1pt-tall first frame looks like a missed click.
            preparePopoverContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func preparePopoverContentSize() {
        guard let hosting = hostingController else { return }
        let fitted = hosting.sizeThatFits(in: NSSize(width: PopoverMetrics.width, height: 10_000))
        let height = max(120, ceil(fitted.height))
        let size = NSSize(width: PopoverMetrics.width, height: height)
        popover?.contentSize = size
        popoverChrome?.noteAppliedHeight(height)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        popoverChrome?.notePopoverDidShow()
        // Defer monitors so the opening click can’t immediately dismiss.
        DispatchQueue.main.async { [weak self] in
            self?.startPopoverDismissMonitor()
            self?.popoverChrome?.syncToMeasuredHeight()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissMonitor()
    }

    private func startPopoverDismissMonitor() {
        stopPopoverDismissMonitor()

        // Clicks in other apps / desktop / other menu-bar items.
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Status-item clicks can surface here depending on activation; never steal the toggle.
            if self.isMouseInStatusItem() { return }
            self.closePopoverFromOutsideClick()
        }

        // Clicks elsewhere in this app (but not inside the popover).
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let popover = self.popover, popover.isShown else { return event }
            if self.isEvent(event, inside: popover) {
                return event
            }
            // Keep status-item clicks so togglePopover can handle them.
            if self.isMouseInStatusItem() {
                return event
            }
            self.closePopoverFromOutsideClick()
            return event
        }
    }

    private func stopPopoverDismissMonitor() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

    private func closePopoverFromOutsideClick() {
        guard popover?.isShown == true else { return }
        popover?.performClose(nil)
    }

    private func isEvent(_ event: NSEvent, inside popover: NSPopover) -> Bool {
        guard let contentView = popover.contentViewController?.view,
              let window = contentView.window
        else { return false }

        if event.window === window {
            let point = event.locationInWindow
            return contentView.bounds.contains(contentView.convert(point, from: nil))
        }

        // Screen-space fallback for some event deliveries.
        return window.frame.contains(NSEvent.mouseLocation)
    }

    /// Screen-space hit test — status-item events often don’t share `event.window` with the button.
    private func isMouseInStatusItem() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        return screenRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func nsColor(from color: Color) -> NSColor {
        NSColor(color)
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

        let darkBar = isDarkMenuBar(appearance)
        let paint: NSColor = isEngaged
            ? contrastAdjusted(color, againstDarkBackground: darkBar)
            : .black

        // Silence → circle; audio → organic blob (logo silhouette).
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

    /// Status items briefly report a light default appearance before attaching to the menu bar.
    private static func isDarkMenuBar(_ appearance: NSAppearance?) -> Bool {
        isDark(appearance ?? NSApp.effectiveAppearance)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Lift dark colors on dark bars / deepen pale colors on light bars, keep hue.
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

// MARK: - Popover sizing

private enum PopoverMetrics {
    static let width: CGFloat = 320
}

/// Bridges SwiftUI layout ↔ NSPopover height.
/// Disclosure expand/collapse animates `contentSize` with the same duration/curve as
/// the SwiftUI height clip — like a CSS height transition, not display:none.
@MainActor
final class PopoverChrome: ObservableObject {
    static let disclosureDuration: TimeInterval = 0.28

    /// Increments each time the menu popover opens — SwiftUI `onDisappear` is unreliable
    /// with NSPopover because the hosting view stays mounted.
    @Published private(set) var presentationID: Int = 0

    private weak var popover: NSPopover?
    private(set) var isDisclosureAnimating = false
    private var measuredHeight: CGFloat = 0
    private var disclosureTimer: Timer?

    func attach(_ popover: NSPopover) {
        self.popover = popover
    }

    func notePopoverDidShow() {
        presentationID += 1
    }

    /// Live laid-out height from GeometryReader. Ignored while disclosure is animating
    /// so we don't snap to SwiftUI's end-state intrinsic size mid-transition.
    func reportMeasuredHeight(_ height: CGFloat) {
        measuredHeight = max(1, ceil(height))
        guard !isDisclosureAnimating else { return }
        applyHeight(measuredHeight)
    }

    func syncToMeasuredHeight() {
        guard measuredHeight > 1 else { return }
        applyHeight(measuredHeight)
    }

    /// Seed chrome’s idea of height after an external `contentSize` set (e.g. before show).
    func noteAppliedHeight(_ height: CGFloat) {
        measuredHeight = max(1, ceil(height))
    }

    /// Animate popover height by the disclosure delta in lockstep with SwiftUI.
    func animateDisclosure(deltaHeight: CGFloat) {
        guard let popover, abs(deltaHeight) > 0.5 else { return }

        disclosureTimer?.invalidate()
        isDisclosureAnimating = true

        let from = popover.contentSize.height
        let to = max(1, from + deltaHeight)
        let duration = Self.disclosureDuration
        let start = ProcessInfo.processInfo.systemUptime

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let linear = min(1, elapsed / duration)
                // Match SwiftUI `.easeInOut` (smoothstep).
                let eased = linear * linear * (3 - 2 * linear)
                let height = from + (to - from) * CGFloat(eased)
                self.applyHeight(height)

                if linear >= 1 {
                    timer.invalidate()
                    self.disclosureTimer = nil
                    self.isDisclosureAnimating = false
                    // Correct any estimate drift against the real laid-out height.
                    DispatchQueue.main.async {
                        self.syncToMeasuredHeight()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        disclosureTimer = timer
    }

    private func applyHeight(_ height: CGFloat) {
        guard let popover else { return }
        let size = NSSize(width: PopoverMetrics.width, height: max(1, height))
        guard abs(popover.contentSize.height - size.height) > 0.25 else { return }
        popover.contentSize = size
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
            .frame(width: PopoverMetrics.width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
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
