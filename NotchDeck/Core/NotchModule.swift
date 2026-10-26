import SwiftUI

@MainActor
protocol NotchModule: AnyObject {
    var id: ModuleID { get }
    /// Has something live right now (drives the collapsed "live activity" pill).
    var isLive: Bool { get }
    /// Higher wins the collapsed leading slot. Guide: AI thinking 100, Metro bundling 90,
    /// music playing 50, lyrics 40, idle 0.
    var compactPriority: Int { get }
    /// Collapsed views. Height = notch height (~32pt). Max width each side = NotchMetrics.compactSideWidth (≈ 76pt).
    func compactLeading() -> AnyView
    func compactTrailing() -> AnyView
    /// Expanded content. Fits in NotchMetrics.expandedContentSize (≈ 500 x 170 pt). Dark background, white text.
    func expanded() -> AnyView
    /// Optional per-module section in the Settings window (Form section content).
    func settings() -> AnyView?
    /// Optional one-row banner content for the compact peek (see `PeekStyle.compact`).
    /// Laid out in roughly (banner width - 28) x 26pt, font ~12-13pt. Return nil to fall back
    /// to the live-activity pill with this module's compact slots forced in for the peek.
    func peekContent() -> AnyView?
    /// Icons for the collapsed live notch (see `CompactItem`). Must be a protocol requirement so overrides are called.
    func compactItems() -> [CompactItem]
    /// Optional pane for the combined Home dashboard. Sized by the dashboard (see DashboardModule).
    func dashboardSection() -> AnyView?
    /// Content size this module wants when expanded. The notch shape animates to it.
    var preferredExpandedSize: CGSize { get }
    func start()
    func stop()
}

/// One small icon in the collapsed live notch. The notch shows at most 4 (2 per side), lowest `rank` first.
struct CompactItem: Identifiable {
    static let iconSize: CGFloat = 22
    let id: String
    let rank: Int
    let view: AnyView
}

extension NotchModule {
    /// Icons this module contributes while live. Default: its compactLeading as a single icon.
    func compactItems() -> [CompactItem] {
        guard isLive else { return [] }
        return [CompactItem(id: id.rawValue, rank: id.compactRank,
                            view: AnyView(compactLeading().frame(width: CompactItem.iconSize, height: CompactItem.iconSize).clipped()))]
    }
    func peekContent() -> AnyView? { nil }
    func dashboardSection() -> AnyView? { nil }
    var preferredExpandedSize: CGSize { NotchMetrics.expandedContentSize }
}
