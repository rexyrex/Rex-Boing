import AppKit
import QuartzCore

// Checks the menu bar drawing path without needing a menu bar.
//
//   swiftc -O -o /tmp/visual-check Tools/visual-check.swift \
//     RexBoing/StatusBar/Visualizer.swift RexBoing/StatusBar/VisualCanvas.swift
//   /tmp/visual-check
//
// Drives the real CALayer delegate for every visualiser and compares what
// CoreAnimation produced against the same instant rendered directly — that
// catches a delegate that is never called and any drift between the on-screen
// path and the one the previews and README figures use. A second pass drives
// the same delegate with a *flipped* context — the top-left-origin transform
// CoreAnimation hands it inside the status button's layer tree, measured in
// the running app as d = -scale, ty = height x scale — and requires the same
// pixels. A standalone layer is never flipped, so without this pass the
// delegate's un-flip branch was dead in the harness: deleting it entirely
// still printed PASS while the live menu bar drew every rex upside-down.
@main
enum VisualCheck {
    /// `contentsAreFlipped()` is what the delegate consults; inside the real
    /// status item it answers true. This stands in for the button's tree.
    private final class FlippedLayer: CALayer {
        override func contentsAreFlipped() -> Bool { true }
    }

    @MainActor
    static func run() {
        var failures = 0
        for visual in Visualizer.allCases {
          for scale in [1.0, 2.0] {
           for load in [0.0, 0.5, 1.0] {
            for time in [0.0, 0.125, 0.25, 0.40, 0.625, 0.875, 1.3, 4.3] {
            let canvas = VisualCanvas()
            canvas.visual = visual
            canvas.time = time
            canvas.load = load
            canvas.color = .white

            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: Visualizer.canvasSize.width, height: Visualizer.canvasSize.height)
            layer.contentsScale = scale
            layer.delegate = canvas
            layer.setNeedsDisplay()
            layer.displayIfNeeded()

            let shot = CGContext(
                data: nil, width: Int(Visualizer.canvasSize.width * scale), height: Int(Visualizer.canvasSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            shot.scaleBy(x: scale, y: scale)
            layer.render(in: shot)
            let rep = NSBitmapImageRep(cgImage: shot.makeImage()!)

            let reference = CGContext(
                data: nil, width: Int(Visualizer.canvasSize.width * scale), height: Int(Visualizer.canvasSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            reference.scaleBy(x: scale, y: scale)
            visual.draw(
                in: reference, rect: NSRect(x: 0, y: 0, width: Visualizer.canvasSize.width, height: Visualizer.canvasSize.height),
                time: time, load: load, color: .white)
            let referenceRep = NSBitmapImageRep(cgImage: reference.makeImage()!)

            // The flipped pass: same delegate, same instant, but through the
            // transform the status button's tree hands it. Un-flipped
            // correctly, the buffer must match the reference exactly; with
            // the compensation branch broken it comes out mirrored and every
            // ink pixel mismatches.
            let flippedLayer = FlippedLayer()
            flippedLayer.frame = CGRect(x: 0, y: 0, width: Visualizer.canvasSize.width, height: Visualizer.canvasSize.height)
            flippedLayer.contentsScale = scale
            guard flippedLayer.contentsAreFlipped() else {
                fatalError("flipped harness is inert — FlippedLayer no longer reports as flipped")
            }
            let flipped = CGContext(
                data: nil, width: Int(Visualizer.canvasSize.width * scale), height: Int(Visualizer.canvasSize.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            flipped.translateBy(x: 0, y: Visualizer.canvasSize.height * scale)
            flipped.scaleBy(x: scale, y: -scale)
            canvas.draw(flippedLayer, in: flipped)
            let flippedRep = NSBitmapImageRep(cgImage: flipped.makeImage()!)

            var ink = 0, mismatched = 0, flipMismatched = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let a = rep.colorAt(x: x, y: y)!.alphaComponent
                    let b = referenceRep.colorAt(x: x, y: y)!.alphaComponent
                    let c = flippedRep.colorAt(x: x, y: y)!.alphaComponent
                    if a > 0.2 { ink += 1 }
                    if abs(a - b) > 0.25 { mismatched += 1 }
                    if abs(c - b) > 0.25 { flipMismatched += 1 }
                }
            }
            // Ink is measured in pixels, so scale the area floor for 1× displays.
            let ok = Double(ink) > 10 * scale * scale && mismatched == 0 && flipMismatched == 0
            if !ok { failures += 1; print("Frame: time=\(time), load=\(load), scale=\(scale)") }
            print(String(
                format: "%-10@ ink %4d px, differs %3d px, flipped differs %3d px  %@",
                visual.rawValue as NSString, ink, mismatched, flipMismatched,
                (ok ? "PASS" : "FAIL") as NSString))
        }
          }
         }
        }
        print(failures == 0
            ? "PASS: every visualiser draws through CoreAnimation exactly as rendered directly, flipped trees included"
            : "FAIL: \(failures) frame(s) differ")
        exit(failures == 0 ? 0 : 1)
    }

    static func main() { MainActor.assumeIsolated { run() } }
}
