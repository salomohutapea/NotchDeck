import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar on every space
/// (including over full-screen apps) and never takes focus.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = true
    }

    /// Key only while the notch is expanded so module text fields can receive typing.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// The panel never becomes active, so without this the first click only "focuses" it and a drag
/// (banner slider, playback scrubber) needs a second click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
