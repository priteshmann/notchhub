import SwiftUI

/// The black shape. Top edge is flush with the screen; the two top corners are CONCAVE fillets
/// (the shape flares into the menu bar like the hardware notch does), the bottom corners convex.
/// `fillet` = 0 gives a plain notch-sized rectangle with rounded bottom corners (idle state).
struct NotchShape: Shape {
    var fillet: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fillet, bottomRadius) }
        set {
            fillet = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in r: CGRect) -> Path {
        let f = max(0, min(fillet, r.height / 2, r.width / 4))
        let innerWidth = r.width - 2 * f
        let rad = max(0, min(bottomRadius, (r.height - f), innerWidth / 2))
        let left = r.minX + f
        let right = r.maxX - f
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if f > 0 {
            p.addQuadCurve(to: CGPoint(x: left, y: r.minY + f), control: CGPoint(x: left, y: r.minY))
        }
        p.addLine(to: CGPoint(x: left, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: left, y: r.maxY),
                 tangent2End: CGPoint(x: left + rad, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: right - rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: right, y: r.maxY),
                 tangent2End: CGPoint(x: right, y: r.maxY - rad), radius: rad)
        if f > 0 {
            p.addLine(to: CGPoint(x: right, y: r.minY + f))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: right, y: r.minY))
        } else {
            p.addLine(to: CGPoint(x: right, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}
