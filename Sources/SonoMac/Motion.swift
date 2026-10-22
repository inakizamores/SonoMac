import SwiftUI
import AppKit

/// One motion vocabulary for the panel. The window and its content follow
/// the same spring, so lower rows ride the window's bottom edge the way the
/// system menus (Wi-Fi's "Other Networks") open: a quick start, a small
/// overshoot, then a settle.
enum PanelMotion {
    static let spring = Spring(duration: 0.42, bounce: 0.2)
}

extension Animation {
    /// Panel growth and shrink, matched to the window's own resize.
    static let panel = Animation.spring(PanelMotion.spring)
}

extension AnyTransition {
    /// Rows fade in once the window has mostly opened out for them, and
    /// fade out quickly as it closes, so text is never drawn mid-squeeze.
    static let panelRow = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.14)),
        removal: .opacity.animation(.easeIn(duration: 0.08))
    )
}

/// The panel's height, sprung frame by frame toward the content's own on
/// the same spring the content animates with. A menu bar window only takes
/// its content's final size, all at once, so its height has to come from
/// here for the window to move with the content.
@Observable @MainActor
final class PanelHeight: NSObject {
    private(set) var value: CGFloat = 0
    @ObservationIgnored private var target: CGFloat = 0
    // The running spring: from `from`, heading by `delta`, started at
    // `start` with velocity `v0`.
    @ObservationIgnored private var from: CGFloat = 0
    @ObservationIgnored private var delta: CGFloat = 0
    @ObservationIgnored private var v0: CGFloat = 0
    @ObservationIgnored private var start: CFTimeInterval = 0
    @ObservationIgnored private var link: CADisplayLink?

    /// Springs to `height`. A change mid-way carries the current speed
    /// into the new target, as SwiftUI's own springs do. The first height
    /// is taken as is.
    func spring(to height: CGFloat) {
        guard value > 0 else {
            target = height
            value = height
            return
        }
        guard abs(height - target) > 0.25 else { return }
        let now = CACurrentMediaTime()
        var velocity: CGFloat = 0
        if link != nil {
            velocity = PanelMotion.spring.velocity(target: delta, initialVelocity: v0, time: now - start)
        }
        from = value
        delta = height - value
        v0 = velocity
        start = now
        target = height
        if link == nil, let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }
        if link == nil { value = height }
    }

    /// Forgets the height while the panel is closed, so it opens at its
    /// content's size rather than springing from the last one.
    func reset() {
        stop()
        value = 0
    }

    @objc private func step(_ l: CADisplayLink) {
        let t = CACurrentMediaTime() - start
        if t >= PanelMotion.spring.settlingDuration(target: delta, initialVelocity: v0, epsilon: 0.25) {
            value = target
            stop()
        } else {
            value = from + PanelMotion.spring.value(target: delta, initialVelocity: v0, time: t)
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }
}

/// Sizes the panel's window to its content on the panel spring, content
/// hanging from the top. Its own view, so each frame of the spring
/// re-renders only this, not the panel.
/// Left out of README screenshots, which have no window and can't draw
/// AppKit views.
struct PanelSizer: ViewModifier {
    @Environment(\.isScreenshotting) private var isScreenshotting
    @State private var height = PanelHeight()

    func body(content: Content) -> some View {
        if isScreenshotting {
            content
        } else {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.spring(to: $0) }
                .frame(height: height.value > 0 ? height.value : nil, alignment: .top)
                .background { WindowFitter(height: height.value) }
                .onDisappear { height.reset() }
        }
    }
}

/// Keeps the window's height on the panel's, top fixed under the menu bar.
/// The window grows to fit its content by itself but never shrinks.
private struct WindowFitter: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ nsView: FitterView, context: Context) {
        nsView.fit(height: height)
    }

    final class FitterView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func fit(height: CGFloat) {
            guard let w = window, height > 0 else { return }
            let f = w.frame
            guard abs(f.height - height) > 0.25 else { return }
            w.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height),
                       display: true)
        }
    }
}
