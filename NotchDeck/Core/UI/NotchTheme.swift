import SwiftUI

enum NotchTheme {
    static let background = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let surface = Color.white.opacity(0.08)
    static let surfaceStrong = Color.white.opacity(0.16)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let success = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.35)

    static let titleFont = Font.system(size: 14, weight: .semibold)
    static let bodyFont = Font.system(size: 12, weight: .regular)
    static let captionFont = Font.system(size: 10.5, weight: .medium)
    static let monoFont = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// Resize spring for the user's chosen animation style (Settings → General).
    static var spring: Animation { AnimationStyle.current.animation }
}
