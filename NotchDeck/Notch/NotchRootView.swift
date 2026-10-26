import SwiftUI

/// Scale factors of the squash-and-stretch overshoot (anchored at the top edge).
private struct JellyScale {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

struct NotchRootView: View {
    let context: NotchScreenContext

    private let coordinator = NotchCoordinator.shared
    private let registry = ModuleRegistry.shared
    private let settings = AppSettings.shared

    /// Peak scale offsets for the pending jelly animation, set whenever the shape size changes.
    @State private var jellyPeak = JellyScale()
    @State private var jellyTrigger = 0

    var body: some View {
        let layout = context.layout
        let size = context.size(for: layout)
        let radii = context.radii(for: layout)
        let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom, floating: context.isFloating)
        let style = settings.animationStyle
        let spring = style.animation
        let shadowOpacity: Double = layout == .expanded ? 0.45 : (layout == .peek ? 0.28 : (context.isFloating ? 0.3 : 0))
        let peak = jellyPeak

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                switch layout {
                case .collapsed:
                    Color.clear
                case .live:
                    LiveActivityView(context: context)
                        .transition(.opacity)
                case .peek:
                    PeekBannerView(context: context)
                        .transition(.opacity)
                case .expanded:
                    ExpandedView(context: context)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: .black.opacity(shadowOpacity),
                        radius: layout == .peek ? 6 : 12, y: layout == .peek ? 3 : 5)
            // Squash and stretch: a short anisotropic overshoot after each size change. Peak scale is
            // at most ~4%, well inside the panel's transparent margin, so the shape never clips.
            .keyframeAnimator(initialValue: JellyScale(), trigger: jellyTrigger) { content, value in
                content.scaleEffect(x: value.x, y: value.y, anchor: .top)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    CubicKeyframe(peak.x, duration: 0.13)
                    CubicKeyframe(1 - (peak.x - 1) * 0.45, duration: 0.15)
                    SpringKeyframe(1, duration: 0.22, spring: .bouncy)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(peak.y, duration: 0.13)
                    CubicKeyframe(1 - (peak.y - 1) * 0.45, duration: 0.15)
                    SpringKeyframe(1, duration: 0.22, spring: .bouncy)
                }
            }
            .onTapGesture {
                if layout != .expanded { coordinator.expand(on: context.displayID) }
            }
            .padding(.top, context.topOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: layout)
        .animation(spring, value: size)
        .animation(spring, value: context.topOffset)
        .onChange(of: size) { old, new in
            guard style == .jelly, old != .zero, new != old else { return }
            jellyPeak = Self.jellyPeak(from: old, to: new)
            jellyTrigger &+= 1
        }
        .environment(\.colorScheme, .dark)
    }

    /// Width overshoots while height lags when the shape widens (and the other way round for height).
    /// Deltas are normalised so small tweaks (a slider drag) stay almost still.
    private static func jellyPeak(from old: CGSize, to new: CGSize) -> JellyScale {
        func norm(_ d: CGFloat, _ unit: CGFloat) -> CGFloat { max(-1, min(1, d / unit)) }
        let dw = norm(new.width - old.width, 160)
        let dh = norm(new.height - old.height, 110)
        let x = 1 + 0.032 * dw - 0.018 * dh
        let y = 1 + 0.030 * dh - 0.022 * dw
        return JellyScale(x: max(0.96, min(1.04, x)), y: max(0.96, min(1.04, y)))
    }

    static func radii(for layout: NotchLayout) -> (top: CGFloat, bottom: CGFloat) {
        switch layout {
        case .collapsed: return (NotchMetrics.collapsedTopRadius, NotchMetrics.collapsedBottomRadius)
        case .live: return (NotchMetrics.liveTopRadius, NotchMetrics.liveBottomRadius)
        case .peek: return (NotchMetrics.peekTopRadius, NotchMetrics.peekBottomRadius)
        case .expanded: return (NotchMetrics.expandedTopRadius, NotchMetrics.expandedBottomRadius)
        }
    }
}

// MARK: - Live activity (collapsed, widened)

private struct LiveActivityView: View {
    let context: NotchScreenContext
    private let registry = ModuleRegistry.shared

    var body: some View {
        if let forced = forcedPeekModule() {
            // Compact peek of a module without banner content: its compact slots on both sides.
            HStack(spacing: 0) {
                slot([forced.compactLeading()], alignment: .leading)
                Color.clear.frame(width: context.centerGap)
                slot([forced.compactTrailing()], alignment: .trailing)
            }
            .frame(height: context.notchSize.height)
        } else {
            // Up to 4 icons by priority: the top two sit next to the notch, the next two outside them.
            let items = Array(registry.compactItems.prefix(4))
            let inner = items.prefix(2).map { $0 }
            let leftItems = [items.count > 2 ? items[2] : nil, inner.first].compactMap { $0 }
            let rightItems = [inner.count > 1 ? inner[1] : nil, items.count > 3 ? items[3] : nil].compactMap { $0 }
            HStack(spacing: 0) {
                slot(leftItems.map(\.view), ids: leftItems.map(\.id), alignment: .leading)
                Color.clear.frame(width: context.centerGap)
                slot(rightItems.map(\.view), ids: rightItems.map(\.id), alignment: .trailing)
            }
            .frame(height: context.notchSize.height)
            .animation(.easeInOut(duration: 0.2), value: items.map(\.id))
        }
    }

    private func forcedPeekModule() -> (any NotchModule)? {
        if case .peeking(let id) = NotchCoordinator.shared.state, AppSettings.shared.peekStyle == .compact {
            return registry.module(for: id)
        }
        return nil
    }

    @ViewBuilder
    private func slot(_ views: [AnyView], ids: [String]? = nil, alignment: Alignment) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(views.enumerated()), id: \.offset) { i, v in
                v.id(ids?[i] ?? "\(i)").transition(.opacity)
            }
        }
        .padding(alignment == .leading ? .leading : .trailing, 12)
        .frame(width: NotchMetrics.compactSideWidth, height: context.notchSize.height, alignment: alignment)
        .clipped()
    }
}

// MARK: - Compact peek banner

private struct PeekBannerView: View {
    let context: NotchScreenContext
    private let coordinator = NotchCoordinator.shared
    private let registry = ModuleRegistry.shared

    var body: some View {
        let width = context.size(for: .peek).width - 2 * NotchMetrics.peekHorizontalPadding
        VStack(spacing: 0) {
            // Hardware notch strip stays empty.
            Color.clear.frame(height: context.notchSize.height)
            ZStack {
                if case .peeking(let id) = coordinator.state, let content = registry.module(for: id).peekContent() {
                    content
                        .id(coordinator.peekToken)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: NotchMetrics.peekRowHeight, alignment: .leading)
            .clipped()
            .frame(height: NotchMetrics.peekRowAreaHeight, alignment: .center)
        }
        .foregroundStyle(NotchTheme.primaryText)
    }
}

// MARK: - Expanded

private struct ExpandedView: View {
    let context: NotchScreenContext
    private let coordinator = NotchCoordinator.shared
    private let registry = ModuleRegistry.shared

    var body: some View {
        let tabs = coordinator.tabIDs.map { registry.module(for: $0) }
        let selected = coordinator.shownModuleID.map { registry.module(for: $0) }
        let content = context.expandedContent
        let hPad = NotchMetrics.expandedTopRadius + NotchMetrics.expandedSidePadding

        VStack(spacing: 0) {
            header(enabled: tabs, selected: selected?.id, contentWidth: content.width)
                .frame(height: context.notchSize.height)
                .padding(.horizontal, hPad)

            ZStack {
                if let selected {
                    selected.expanded()
                        .id(selected.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    Text("No modules enabled")
                        .font(NotchTheme.bodyFont)
                        .foregroundStyle(NotchTheme.secondaryText)
                }
            }
            .frame(width: content.width, height: content.height)
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: selected?.id)
            .padding(.bottom, NotchMetrics.expandedBottomPadding)
        }
        .foregroundStyle(NotchTheme.primaryText)
    }

    private func header(enabled: [any NotchModule], selected: ModuleID?, contentWidth: CGFloat) -> some View {
        let total = contentWidth
        let gap: CGFloat = 8
        let side = max(0, (total - context.headerGap) / 2 - gap)
        let plan = TabPlan.make(count: enabled.count, leftWidth: side, rightWidth: side)
        let left = Array(enabled.prefix(plan.left))
        let right = Array(enabled.dropFirst(plan.left).prefix(plan.right))
        let overflow = Array(enabled.dropFirst(plan.left + plan.right))

        return HStack(spacing: 0) {
            // Both groups hug the notch so the tab bar reads as centred on it.
            HStack(spacing: TabPlan.spacing) {
                ForEach(left, id: \.id) { tab($0, selected: selected, width: plan.tabWidth) }
            }
            .padding(.trailing, gap)
            .frame(width: side + gap, alignment: .trailing)

            Color.clear.frame(width: context.headerGap)

            HStack(spacing: TabPlan.spacing) {
                ForEach(right, id: \.id) { tab($0, selected: selected, width: plan.tabWidth) }
                if !overflow.isEmpty {
                    MoreMenu(modules: overflow, selected: selected, width: plan.tabWidth)
                }
                GearButton(width: plan.tabWidth)
                Spacer(minLength: 4)
                // Volume / brightness / battery changes while open (peek banners only show when closed).
                SystemHeaderToast()
                    .animation(.easeOut(duration: 0.18), value: SystemEvents.shared.toast?.id)
            }
            .padding(.leading, gap)
            .frame(width: side + gap, alignment: .leading)
        }
    }

    private func tab(_ module: any NotchModule, selected: ModuleID?, width: CGFloat) -> some View {
        TabButton(module: module, isSelected: module.id == selected, width: width) {
            coordinator.select(module.id)
        }
    }
}

/// Decides how many tabs go on each side of the notch, and how wide they are.
struct TabPlan {
    static let spacing: CGFloat = 4
    var tabWidth: CGFloat
    var left: Int
    var right: Int   // visible tabs on the right (excluding more / gear)

    static func make(count n: Int, leftWidth: CGFloat, rightWidth: CGFloat) -> TabPlan {
        func cap(_ width: CGFloat, _ w: CGFloat, slotsReserved: Int) -> Int {
            max(0, Int(((width + spacing) / (w + spacing)).rounded(.down)) - slotsReserved)
        }
        for w: CGFloat in [30, 24] {
            let capL = cap(leftWidth, w, slotsReserved: 0)
            let capR = cap(rightWidth, w, slotsReserved: 1) // gear
            if capL + capR >= n {
                var l = min(capL, (n + 1) / 2)
                if n - l > capR { l = n - capR }
                return TabPlan(tabWidth: w, left: l, right: n - l)
            }
        }
        // Overflow: 24pt tabs, one extra slot on the right for the "more" button.
        let w: CGFloat = 24
        let capL = cap(leftWidth, w, slotsReserved: 0)
        let capR = cap(rightWidth, w, slotsReserved: 2)
        let visible = min(n, capL + capR)
        let left = max(min(capL, (visible + 1) / 2), visible - capR)
        return TabPlan(tabWidth: w, left: left, right: visible - left)
    }
}

private struct MoreMenu: View {
    let modules: [any NotchModule]
    let selected: ModuleID?
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        let active = modules.contains { $0.id == selected }
        Menu {
            ForEach(modules, id: \.id) { m in
                Button {
                    NotchCoordinator.shared.select(m.id)
                } label: {
                    Label(m.id.title, systemImage: m.id.systemImage)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? Color.white : NotchTheme.secondaryText)
                .frame(width: width, height: 24)
                .background(Capsule().fill(active ? NotchTheme.surfaceStrong : (hovering ? NotchTheme.surface : .clear)))
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("More modules")
    }
}

private struct TabButton: View {
    let module: any NotchModule
    let isSelected: Bool
    var width: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: module.id.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : NotchTheme.secondaryText)
                .frame(width: width, height: 24)
                .background(
                    Capsule().fill(isSelected ? NotchTheme.surfaceStrong : (hovering ? NotchTheme.surface : .clear))
                )
                .overlay(alignment: .topTrailing) {
                    if module.isLive && !isSelected {
                        Circle().fill(NotchTheme.success).frame(width: 5, height: 5).offset(x: -3, y: 3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(module.id.title)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

private struct GearButton: View {
    var width: CGFloat = 30
    @State private var hovering = false
    var body: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : NotchTheme.secondaryText)
                .frame(width: width, height: 24)
                .background(Capsule().fill(hovering ? NotchTheme.surface : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings")
    }
}
