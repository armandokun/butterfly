import SwiftUI

/// Notch silhouette: concave flare into the menu bar at the top, rounded at the bottom.
/// Same geometry as DynamicNotch (jackson-storm); radii animate between states.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top),
                       control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY),
                       control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom),
                       control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Screens without a notch (external displays): a floating Dynamic Island pill.
struct IslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in r: CGRect) -> Path {
        let c = max(0, min(radius, min(r.width, r.height) / 2))
        return Path(roundedRect: r, cornerSize: .init(width: c, height: c), style: .continuous)
    }
}

/// Either silhouette, so one view can morph notch ↔ island.
struct SurfaceShape: Shape {
    var island: Bool
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        island ? IslandShape(radius: bottom).path(in: r) : NotchShape(top: top, bottom: bottom).path(in: r)
    }
}

/// DynamicNotch's content transition: blur + squash toward the notch + fade.
struct NotchTransitionModifier: ViewModifier {
    var blur: CGFloat = 0
    var opacity: Double = 1
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: max(0.001, scaleX), y: max(0.001, scaleY), anchor: .center)
            .offset(y: offsetY)
            .blur(radius: blur)
            .opacity(opacity)
            .compositingGroup()
    }
}

extension AnyTransition {
    static func notch(expanded: Bool, lift: CGFloat) -> AnyTransition {
        let active = expanded
            ? NotchTransitionModifier(blur: 15, opacity: 0, offsetY: -lift, scaleX: 0.6, scaleY: 0.2)
            : NotchTransitionModifier(blur: 10, opacity: 0, scaleX: 0.7, scaleY: 1)
        return .modifier(active: active, identity: NotchTransitionModifier())
    }
}
