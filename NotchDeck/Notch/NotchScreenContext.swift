import AppKit
import SwiftUI

enum NotchLayout: Hashable {
    case collapsed, live, peek, expanded
}

/// Per-screen geometry plus the layout derived from global state.
@MainActor
final class NotchScreenContext {
    let displayID: CGDirectDisplayID
    /// Hardware notch size, or the default capsule size on displays without a notch.
    let baseSize: CGSize
    let hasNotch: Bool
    let centerX: CGFloat
    let screenMaxY: CGFloat

    private let coordinator = NotchCoordinator.shared
    private let settings = AppSettings.shared
    private let registry = ModuleRegistry.shared

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.hasNotch = NotchMetrics.hasNotch(screen)
        self.baseSize = NotchMetrics.notchSize(for: screen)
        self.centerX = NotchMetrics.notchCenterX(for: screen)
        self.screenMaxY = screen.frame.maxY
    }

    /// Displays without a notch draw a floating capsule instead of a notch.
    var isFloating: Bool { !hasNotch }

    /// Gap between the screen's top edge and the shape (capsule only).
    var topOffset: CGFloat { isFloating ? NotchMetrics.floatingTopGap : 0 }

    /// Collapsed shape size: the base size plus the user's extra width / height (notched displays only).
    /// Reads observable settings, so SwiftUI bodies calling it update live.
    var notchSize: CGSize {
        guard hasNotch else { return baseSize }
        return CGSize(width: max(40, baseSize.width + settings.notchExtraWidth),
                      height: baseSize.height + settings.notchExtraHeight)
    }

    /// Width kept clear in the middle of live / peek / expanded strips: never narrower than the
    /// hardware notch, even when the user shrinks the collapsed shape.
    var centerGap: CGFloat { max(notchSize.width, baseSize.width) }

    /// Gap between the two tab groups in the expanded header (capsules have no hardware to avoid).
    var headerGap: CGFloat { isFloating ? 24 : centerGap }

    /// Corner radii for a layout (flared top corners on a notch, plain rounded corners on a capsule).
    func radii(for layout: NotchLayout) -> (top: CGFloat, bottom: CGFloat) {
        guard isFloating else { return NotchRootView.radii(for: layout) }
        switch layout {
        case .collapsed, .live:
            let r = notchSize.height / 2
            return (r, r)
        case .peek: return (NotchMetrics.floatingPeekRadius, NotchMetrics.floatingPeekRadius)
        case .expanded: return (NotchMetrics.floatingExpandedTopRadius, NotchMetrics.floatingExpandedBottomRadius)
        }
    }

    /// Reads observable state, so calling it from a SwiftUI body tracks the dependencies.
    var layout: NotchLayout {
        if coordinator.state != .collapsed, coordinator.activeDisplay == displayID {
            if case .peeking(let id) = coordinator.state, settings.peekStyle == .compact {
                return registry.module(for: id).peekContent() != nil ? .peek : .live
            }
            return .expanded
        }
        if settings.showLiveActivities, !registry.compactItems.isEmpty { return .live }
        return .collapsed
    }

    func size(for layout: NotchLayout) -> CGSize {
        switch layout {
        case .collapsed: return notchSize
        case .live:
            return CGSize(width: centerGap + 2 * NotchMetrics.compactSideWidth, height: notchSize.height)
        case .peek:
            return CGSize(width: centerGap + 2 * NotchMetrics.peekSideWidth,
                          height: notchSize.height + NotchMetrics.peekRowAreaHeight)
        case .expanded: return NotchMetrics.expandedSize(notchHeight: notchSize.height, content: expandedContent)
        }
    }

    /// Content area of the module currently shown (tracks selection, so animates tab switches).
    var expandedContent: CGSize {
        guard let id = coordinator.shownModuleID else { return NotchMetrics.expandedContentSize }
        return registry.module(for: id).preferredExpandedSize
    }

    /// Global-coordinate rect around the shape (which sits `topOffset` below the screen's top edge).
    /// The rect extends past the screen's top edge so a pointer pushed against it still counts.
    private func rect(size s: CGSize, padX: CGFloat, padBottom: CGFloat) -> NSRect {
        NSRect(x: centerX - s.width / 2 - padX,
               y: screenMaxY - topOffset - s.height - padBottom,
               width: s.width + 2 * padX,
               height: s.height + topOffset + padBottom + 4)
    }

    /// Forgiving rect used to detect a drag approaching the notch.
    func dragRect() -> NSRect {
        let l = layout
        return rect(size: size(for: l), padX: l == .expanded ? 14 : 50, padBottom: l == .expanded ? 14 : 36)
    }

    /// Pointer hit rect in global screen coordinates for the current layout.
    func hitRect() -> NSRect {
        let l = layout
        return rect(size: size(for: l), padX: l == .expanded ? 14 : 3, padBottom: l == .expanded ? 14 : 2)
    }

    /// True when `point` (global coordinates) is in the header strip: the notch-height band at
    /// the top of the shape (tab row when expanded), plus a few points of slack.
    func isInHeader(_ point: NSPoint) -> Bool {
        point.y >= screenMaxY - topOffset - notchSize.height - 8
    }
}
