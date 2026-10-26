import AppKit

/// Turns scroll-wheel / trackpad events over the notch into gestures.
///
/// - Expanded: a sideways swipe switches to the next / previous tab (once per gesture, ~60pt),
///   an upward swipe (~40pt) collapses the notch.
/// - Collapsed / live / peek: a downward swipe (~40pt) expands the notch.
///
/// Module content keeps its own scrolling. A vertical-up swipe only collapses when the pointer is in
/// the header strip (notch height + a little slack, i.e. the tab row) or when the view under the
/// pointer has no vertically scrollable NSScrollView (so nothing would consume the scroll anyway).
/// Likewise a sideways swipe over a horizontally scrollable view is left to that view.
@MainActor
final class NotchGestureHandler {
    static let collapseThreshold: CGFloat = 40
    static let tabThreshold: CGFloat = 60
    static let expandThreshold: CGFloat = 40
    private static let axisLockDistance: CGFloat = 8
    private static let wheelGestureGap: TimeInterval = 0.3

    private enum Axis { case horizontal, vertical }

    /// Accumulated finger travel in "finger" directions: +x right, +y up (independent of the
    /// natural-scrolling preference).
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var axis: Axis?
    private var fired = false
    /// Gesture was recognised as ours: remaining events (incl. momentum) are swallowed.
    private var claimed = false
    /// Gesture belongs to a scroll view underneath: ignore it until the next one starts.
    private var passThrough = false
    private var lastEventTime: TimeInterval = 0

    func reset() { resetGesture() }

    private func resetGesture() {
        accX = 0; accY = 0; axis = nil; fired = false; claimed = false; passThrough = false
    }

    /// Returns true when the event was consumed (local monitor should drop it).
    func handle(_ event: NSEvent, context: NotchScreenContext, panel: NotchPanel?) -> Bool {
        let settings = AppSettings.shared
        guard settings.gesturesEnabled else { resetGesture(); return false }

        let isMomentum = !event.momentumPhase.isEmpty
        let hasPhase = !event.phase.isEmpty || isMomentum
        // Start of a new gesture.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            resetGesture()
        } else if !hasPhase, event.timestamp - lastEventTime > Self.wheelGestureGap {
            resetGesture() // classic wheel: no phases, so a pause separates gestures
        }
        lastEventTime = event.timestamp
        defer {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                // Momentum may follow; it is swallowed via `claimed`, which resets with the next gesture.
                if event.momentumPhase.isEmpty && !claimed { resetGesture() }
            }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { resetGesture() }
        }

        if passThrough { return false }
        if isMomentum { return claimed }

        // Normalise to finger direction: natural scrolling flips the delta signs.
        let inverted = event.isDirectionInvertedFromDevice
        let fingerRight = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerUp = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        accX += fingerRight
        accY += fingerUp

        if axis == nil, max(abs(accX), abs(accY)) > Self.axisLockDistance {
            axis = abs(accX) > abs(accY) * 1.2 ? .horizontal : (abs(accY) > abs(accX) * 1.2 ? .vertical : nil)
        }
        guard let axis else { return false }
        if fired { return true }

        let coordinator = NotchCoordinator.shared
        let location = NSEvent.mouseLocation
        let layout = context.layout

        if layout == .expanded {
            let scrollView = panel.flatMap { Self.scrollView(under: location, in: $0) }
            switch axis {
            case .vertical:
                // A scroll view that can scroll vertically keeps the gesture, except in the header strip.
                if !context.isInHeader(location), Self.canScroll(scrollView, vertical: true) {
                    passThrough = true
                    return false
                }
                if accY >= Self.collapseThreshold {
                    fired = true; claimed = true
                    coordinator.collapse()
                    return true
                }
                return false
            case .horizontal:
                if Self.canScroll(scrollView, vertical: false) { passThrough = true; return false }
                if abs(accX) >= Self.tabThreshold {
                    fired = true; claimed = true
                    // Fingers moving left reveal the next tab.
                    coordinator.selectAdjacent(accX < 0 ? 1 : -1)
                    return true
                }
                return false
            }
        } else if axis == .vertical, accY <= -Self.expandThreshold {
            fired = true; claimed = true
            coordinator.expand(on: context.displayID)
            return true
        }
        return false
    }

    // MARK: Scroll view discovery

    /// The nearest scroll view under a global screen point (SwiftUI ScrollView / List are NSScrollViews).
    private static func scrollView(under screenPoint: NSPoint, in panel: NSPanel) -> NSScrollView? {
        guard let content = panel.contentView else { return nil }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let inSuper = content.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint
        var view = content.hitTest(inSuper)
        while let v = view {
            if let sv = v as? NSScrollView { return sv }
            view = v.superview
        }
        return nil
    }

    private static func canScroll(_ scrollView: NSScrollView?, vertical: Bool) -> Bool {
        guard let sv = scrollView, let doc = sv.documentView else { return false }
        let visible = sv.contentView.bounds.size
        return vertical ? doc.frame.height > visible.height + 1 : doc.frame.width > visible.width + 1
    }
}
