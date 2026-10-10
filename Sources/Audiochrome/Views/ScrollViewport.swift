import AppKit
import SwiftUI

/// Vertical `ScrollView` with light edge shadows while more content is off-screen.
struct ScrollViewport<Content: View>: View {
    var showsIndicators: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var showTop = false
    @State private var showBottom = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            content()
                .background {
                    ScrollEdgeMonitor { top, bottom in
                        showTop = top
                        showBottom = bottom
                    }
                }
        }
        .overlay(alignment: .top) {
            edgeShadow(top: true)
                .opacity(showTop ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            edgeShadow(top: false)
                .opacity(showBottom ? 1 : 0)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: showTop)
        .animation(.easeInOut(duration: 0.18), value: showBottom)
    }

    private func edgeShadow(top: Bool) -> some View {
        let strong = Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18)
        let mid = Color.black.opacity(colorScheme == .dark ? 0.18 : 0.07)
        return LinearGradient(
            colors: top
                ? [strong, mid, .clear]
                : [.clear, mid, strong],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 22)
        .allowsHitTesting(false)
    }
}

private struct ScrollEdgeMonitor: NSViewRepresentable {
    var onChange: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> ScrollEdgeMonitorView {
        let view = ScrollEdgeMonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ScrollEdgeMonitorView, context: Context) {
        view.onChange = onChange
        view.report()
    }
}

private final class ScrollEdgeMonitorView: NSView {
    var onChange: ((Bool, Bool) -> Void)?
    private var observations: [NSObjectProtocol] = []
    private var lastTop = false
    private var lastBottom = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        restart()
    }

    deinit {
        stop()
    }

    private func restart() {
        stop()
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observations.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.report()
            }
        )
        if let document = scroll.documentView {
            observations.append(
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: document,
                    queue: .main
                ) { [weak self] _ in
                    self?.report()
                }
            )
        }
        report()
        DispatchQueue.main.async { [weak self] in
            self?.report()
        }
    }

    private func stop() {
        let center = NotificationCenter.default
        observations.forEach { center.removeObserver($0) }
        observations.removeAll()
    }

    func report() {
        guard let scroll = enclosingScrollView else {
            publish(top: false, bottom: false)
            return
        }
        let clip = scroll.contentView.bounds
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let viewHeight = clip.height
        guard viewHeight > 0, documentHeight > 0 else {
            publish(top: false, bottom: false)
            return
        }
        let offsetFromTop: CGFloat
        if scroll.contentView.isFlipped {
            offsetFromTop = clip.origin.y
        } else {
            offsetFromTop = documentHeight - viewHeight - clip.origin.y
        }
        let remaining = documentHeight - viewHeight - offsetFromTop
        publish(top: offsetFromTop > 1.5, bottom: remaining > 1.5)
    }

    private func publish(top: Bool, bottom: Bool) {
        guard top != lastTop || bottom != lastBottom else { return }
        lastTop = top
        lastBottom = bottom
        onChange?(top, bottom)
    }
}
