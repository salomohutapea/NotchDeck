import SwiftUI

/// Notch silhouette. Top edge is full width; the top corners flare outward (concave) like the
/// hardware notch meeting the menu bar; bottom corners are rounded. Fills whatever frame it is
/// given (the root view animates that frame), and animates both radii.
/// With `floating` (displays without a notch) all four corners are plainly rounded: a capsule.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var floating = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if floating { return floatingPath(in: rect) }
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2 - t, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }

    private func floatingPath(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 2, rect.height / 2))
        let b = max(0, min(bottomRadius, rect.width / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY + t), radius: t)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX + t, y: rect.minY), radius: t)
        p.closeSubpath()
        return p
    }
}
