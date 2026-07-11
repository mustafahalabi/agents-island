import SwiftUI

/// The Dynamic Island silhouette: top corners flare *outward* so the shape
/// melts into the notch / menu bar, bottom corners round inward.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = topRadius
        let bottom = min(bottomRadius, (rect.height - top) / 1.2)

        path.move(to: CGPoint(x: 0, y: 0))
        // Top-left outward flare
        path.addQuadCurve(
            to: CGPoint(x: top, y: top),
            control: CGPoint(x: top, y: 0)
        )
        // Left side down
        path.addLine(to: CGPoint(x: top, y: rect.height - bottom))
        // Bottom-left corner
        path.addQuadCurve(
            to: CGPoint(x: top + bottom, y: rect.height),
            control: CGPoint(x: top, y: rect.height)
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.width - top - bottom, y: rect.height))
        // Bottom-right corner
        path.addQuadCurve(
            to: CGPoint(x: rect.width - top, y: rect.height - bottom),
            control: CGPoint(x: rect.width - top, y: rect.height)
        )
        // Right side up
        path.addLine(to: CGPoint(x: rect.width - top, y: top))
        // Top-right outward flare
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.width - top, y: 0)
        )
        path.closeSubpath()
        return path
    }
}

/// Blur + fade + slight scale — the "premium" content morph.
struct BlurFadeModifier: ViewModifier {
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// Content arrives late and fast, letting the container's stretch read
    /// first — the shape expands, then content materializes into it.
    static var islandContentIn: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 8, opacity: 0, scale: 0.97),
            identity: BlurFadeModifier(blur: 0, opacity: 1, scale: 1)
        )
        .animation(.easeOut(duration: 0.26).delay(0.12))
    }

    /// Departing content vanishes quickly so the shape can shrink cleanly.
    static var islandContentOut: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 5, opacity: 0, scale: 0.98),
            identity: BlurFadeModifier(blur: 0, opacity: 1, scale: 1)
        )
        .animation(.easeIn(duration: 0.13))
    }

    static var islandContent: AnyTransition {
        .asymmetric(insertion: .islandContentIn, removal: .islandContentOut)
    }
}

/// Cards slide-and-fade in one after another when the island opens.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -10)
            .blur(radius: shown ? 0 : 4)
            .onAppear {
                // Content transition already waits for the container stretch;
                // cards then settle in short sequence.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)
                    .delay(0.04 + Double(index) * 0.05)) {
                    shown = true
                }
            }
    }
}

extension View {
    func staggeredEntrance(index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}
