import SwiftUI

@main
struct NotchDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All UI is managed manually (notch panels, status item, settings window).
        Settings { EmptyView() }
    }
}
