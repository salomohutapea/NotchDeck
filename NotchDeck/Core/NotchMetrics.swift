import AppKit

enum NotchMetrics {
    static let compactSideWidth: CGFloat = 76
    static let expandedContentSize = CGSize(width: 500, height: 170)
    /// Non-notched screens get a floating capsule of this size.
    static let fallbackNotchSize = CGSize(width: 190, height: 32)
    /// Gap between the top screen edge and a floating capsule.
    static let floatingTopGap: CGFloat = 6
    /// Largest extra collapsed height a user can add on notched displays (reserved in the panel).
    static let maxExtraHeight: CGFloat = 12
    /// Corner radii of the floating capsule per layout (all four corners).
    static let floatingPeekRadius: CGFloat = 18
    static let floatingExpandedTopRadius: CGFloat = 22
    static let floatingExpandedBottomRadius: CGFloat = 26

    // Shape radii per layout.
    static let collapsedTopRadius: CGFloat = 0
    static let collapsedBottomRadius: CGFloat = 9
    static let liveTopRadius: CGFloat = 0
    static let liveBottomRadius: CGFloat = 13
    static let peekTopRadius: CGFloat = 0
    static let peekBottomRadius: CGFloat = 16
    /// Compact peek: each side extends this far beyond the notch (live pill uses compactSideWidth = 76).
    static let peekSideWidth: CGFloat = 100
    /// Height of the content strip under the notch area in a compact peek.
    static let peekRowAreaHeight: CGFloat = 34
    static let peekRowHeight: CGFloat = 26
    static let peekHorizontalPadding: CGFloat = 14
    static let expandedTopRadius: CGFloat = 16
    static let expandedBottomRadius: CGFloat = 26

    /// Horizontal padding inside the expanded shape (beyond the top flare).
    static let expandedSidePadding: CGFloat = 12
    static let expandedBottomPadding: CGFloat = 20
    /// Transparent margin around the max expanded frame inside the panel (shadow room).
    static let panelMargin: CGFloat = 28

    /// Content size of the Devtools terminal: the whole notch is about half the screen in each
    /// direction. Set by the window manager from the largest display.
    @MainActor static var terminalContentSize = CGSize(width: 760, height: 420)

    @MainActor static func updateTerminalSize(for screens: [NSScreen]) {
        guard let big = screens.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let w = big.frame.width / 2 - 2 * (expandedTopRadius + expandedSidePadding)
        let h = big.frame.height / 2 - big.safeAreaInsets.top - expandedBottomPadding - 8
        terminalContentSize = CGSize(width: max(500, w.rounded()), height: max(220, h.rounded()))
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
    }

    static func notchSize(for screen: NSScreen) -> CGSize {
        guard hasNotch(screen),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return fallbackNotchSize }
        let width = screen.frame.width - left.width - right.width
        return CGSize(width: width, height: screen.safeAreaInsets.top)
    }

    /// Horizontal centre of the notch in global screen coordinates.
    static func notchCenterX(for screen: NSScreen) -> CGFloat {
        if hasNotch(screen), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (left.maxX + right.minX) / 2
        }
        return screen.frame.midX
    }

    static func expandedSize(notchHeight: CGFloat, content: CGSize = expandedContentSize) -> CGSize {
        CGSize(
            width: content.width + 2 * (expandedTopRadius + expandedSidePadding),
            height: notchHeight + content.height + expandedBottomPadding
        )
    }

    /// Panel sized for the largest expanded content any module wants. `notchHeight` is the base
    /// (hardware / capsule) height; room for the user's extra height and the capsule gap is added.
    static func panelSize(notchHeight: CGFloat, content: CGSize = expandedContentSize) -> CGSize {
        let e = expandedSize(notchHeight: notchHeight + maxExtraHeight + floatingTopGap, content: content)
        return CGSize(width: e.width + 2 * panelMargin, height: e.height + panelMargin)
    }
}
