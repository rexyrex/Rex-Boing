import AppKit
import QuartzCore

/// Draws the visualiser when CoreAnimation asks for it.
///
/// The obvious approach — render into our own bitmap and assign the result as
/// the layer's `contents` — hands CoreAnimation a brand new `CGImage` every
/// frame, which it has to take ownership of and upload. Acting as the layer's
/// delegate instead lets it keep one backing store for the life of the layer
/// and call back into us to fill it.
///
/// Live either way, and deliberately so. The rigged runner this replaced was a
/// cycle of poses rasterised up front, because a figure was expensive to draw
/// and its motion was periodic. A field is neither: drawing one costs a few
/// dozen microseconds, and its motion is a continuous function of a clock that
/// never wraps — so there is no cycle to cache, and caching one would quantise
/// the exact smoothness the field exists to provide.
@MainActor
final class VisualCanvas: NSObject, @preconcurrency CALayerDelegate {
    /// What to draw at the next display pass. Set by the controller, read on
    /// the callback — which happens in the same CoreAnimation commit, on this
    /// same thread, so there is nothing to synchronise.
    var visual: Visualizer = .rex
    var time: Double = 0
    var load: Double = 0
    var color: NSColor = .labelColor

    func draw(_ layer: CALayer, in context: CGContext) {
        // Inside the status button's layer tree, `contentsAreFlipped()` is
        // true and CoreAnimation hands this delegate a top-left-origin
        // context — measured in the running app: CTM d=-2, ty=height*scale —
        // and unlike a pure CA tree, AppKit's composite does NOT mirror the
        // contents back, so what is drawn flipped stays flipped on screen.
        // `Visualizer.draw` is written for the standard bottom-left Quartz
        // orientation — the one a standalone layer (visual-check, README
        // figures) gets — so normalise here rather than let each visualiser
        // guess which way is up.
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: layer.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        visual.draw(
            in: context,
            rect: CGRect(origin: .zero, size: layer.bounds.size),
            time: time, load: load, color: color)
    }

    /// Suppresses implicit animation on every property of the layer. A
    /// cross-fade between frames reads as motion blur and costs an extra frame
    /// of compositing.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}
