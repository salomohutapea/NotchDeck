import SwiftUI

/// Single-line text that scrolls horizontally (with a pause at the start) when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = NotchTheme.titleFont
    var color: Color = NotchTheme.primaryText
    var speed: CGFloat = 32
    var gap: CGFloat = 36
    var pause: Double = 1.6

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var needsScroll: Bool { containerWidth > 0 && textWidth > containerWidth + 0.5 }

    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { containerWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in containerWidth = w }
                }
            )
            .overlay(alignment: .leading) { scroller }
            .clipped()
            .mask(fade)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var scroller: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !needsScroll)) { tl in
            HStack(spacing: gap) {
                label.background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { textWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in textWidth = w }
                    }
                )
                if needsScroll { label }
            }
            .offset(x: needsScroll ? offset(at: tl.date.timeIntervalSinceReferenceDate) : 0)
        }
        .id(text)
    }

    private func offset(at t: TimeInterval) -> CGFloat {
        let cycle = textWidth + gap
        let scrollTime = Double(cycle / speed)
        let period = pause + scrollTime
        let phase = t.truncatingRemainder(dividingBy: period)
        return phase < pause ? 0 : -CGFloat(phase - pause) * speed
    }

    private var fade: some View {
        LinearGradient(
            stops: needsScroll
                ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                   .init(color: .black, location: 0.94), .init(color: .clear, location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
