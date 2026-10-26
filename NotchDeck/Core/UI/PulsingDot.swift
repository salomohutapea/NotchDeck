import SwiftUI

struct PulsingDot: View {
    var color: Color = NotchTheme.success
    var size: CGFloat = 8
    var isPulsing: Bool = true
    @State private var animate = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.5))
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1)
                    .opacity(animate ? 0 : 0.8)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { animate = true }
        }
    }
}
