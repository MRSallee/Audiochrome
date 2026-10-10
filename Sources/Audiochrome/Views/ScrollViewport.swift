import AppKit
import SwiftUI

/// Vertical `ScrollView` with light edge shadows while more content is off-screen.
struct ScrollViewport<Content: View>: View {
    var showsIndicators: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var topOverflow: CGFloat = 0
    @State private var bottomOverflow: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: showsIndicators) {
            content()
                .background {
                    ScrollEdgeMonitor { top, bottom in
                        topOverflow = top
                        bottomOverflow = bottom
                    }
                }
        }
        .overlay(alignment: .top) {
            edgeShadow(top: true)
                .opacity(edgeOpacity(topOverflow))
        }
        .overlay(alignment: .bottom) {
            edgeShadow(top: false)
                .opacity(edgeOpacity(bottomOverflow))
        }
        .clipped()
    }

    private func edgeOpacity(_ overflow: CGFloat) -> CGFloat {
        min(1, max(0, overflow / 16))
    }

    /// Soft dome: ~10pt of density in the center, fading to 0 at the sides and inward.
    private func edgeShadow(top: Bool) -> some View {
        let strong = Color.black.opacity(colorScheme == .dark ? 0.135 : 0.054)
        let mid = Color.black.opacity(colorScheme == .dark ? 0.05 : 0.02)
        return EllipticalGradient(
            stops: [
                .init(color: strong, location: 0),
                .init(color: mid, location: 0.28),
                .init(color: .clear, location: 1)
            ],
            center: UnitPoint(x: 0.5, y: top ? 0 : 1),
            startRadiusFraction: 0,
            endRadiusFraction: 1
        )
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}

private struct ScrollEdgeMonitor: NSViewRepresentable {
    var onChange: (CGFloat, CGFloat) -> Void

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
    var onChange: ((CGFloat, CGFloat) -> Void)?
    private var observations: [NSObjectProtocol] = []
    private var lastTop: CGFloat = -1
    private var lastBottom: CGFloat = -1

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
            publish(top: 0, bottom: 0)
            return
        }
        let clip = scroll.contentView.bounds
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let viewHeight = clip.height
        guard viewHeight > 0, documentHeight > 0 else {
            publish(top: 0, bottom: 0)
            return
        }
        let offsetFromTop: CGFloat
        if scroll.contentView.isFlipped {
            offsetFromTop = clip.origin.y
        } else {
            offsetFromTop = documentHeight - viewHeight - clip.origin.y
        }
        let remaining = documentHeight - viewHeight - offsetFromTop
        publish(top: max(0, offsetFromTop), bottom: max(0, remaining))
    }

    private func publish(top: CGFloat, bottom: CGFloat) {
        guard abs(top - lastTop) > 0.25 || abs(bottom - lastBottom) > 0.25 else { return }
        lastTop = top
        lastBottom = bottom
        onChange?(top, bottom)
    }
}
