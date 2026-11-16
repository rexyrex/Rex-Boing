import AppKit
import SwiftUI

// Renders the Monitor window's content for the README at 2×, on any display
// or none: the real engine against this machine, the real MonitorView in an
// off-screen window, read back from its layer tree. What it cannot show is
// the title bar and toolbar, which belong to the window and not the view.
//
// Compile with every app source except RexBoingApp.swift (the list
// Tools/check.sh uses for engine-check), then:
//
//   render-monitor <out.png> [seconds] [width] [height] [dark|light] [span]
//
// Samples for `seconds` (default 60) so the graphs have a trace to show.
// Width decides the layout: 1280 (the default) is three columns of cards,
// 1000 two, 680 one. `span` is how many samples the graphs plot (default 90,
// so a minute and a half of sampling fills them).
@main
enum RenderMonitor {
    static let scale: CGFloat = 2

    @MainActor static func main() {
        let args = CommandLine.arguments
        let out = args.count > 1 ? args[1] : "docs/monitor.png"
        let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
        let width = args.count > 3 ? Double(args[3]) ?? 1280 : 1280
        let height = args.count > 4 ? Double(args[4]) ?? 860 : 860
        let dark = !(args.count > 5 && args[5] == "light")
        let span = args.count > 6 ? Int(args[6]) ?? 90 : 90

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = appearance

        let engine = MetricsEngine()
        let preferences = Preferences.shared
        // The tool's own defaults domain, not the app's.
        preferences.monitorSpan = span
        // What the window does when it opens: full-rate process sampling, the
        // detailed samplers, and an immediate tick.
        engine.beginDashboardSampling()
        engine.refreshNow()
        let feed = MonitorFeed(engine: engine)
        feed.resume()

        let hosting = NSHostingView(
            rootView: MonitorView(feed: feed, engine: engine)
                .environmentObject(preferences))
        hosting.wantsLayer = true
        // Far outside every screen: the window has to exist for SwiftUI to
        // lay out and keep updating, but nobody should see it.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = true
        window.contentView = hosting
        window.orderFrontRegardless()

        print("sampling for \(Int(seconds)) s…")
        pump(seconds)
        guard engine.hasReceivedFirstSample else {
            print("engine produced no sample"); exit(1)
        }

        write(snapshot(hosting, dark: dark), to: out)
        engine.endDashboardSampling()
        print("wrote \(out): \(Int(width))×\(Int(height)) pt at \(Int(scale))×")
        exit(0)
    }

    /// Runs the main run loop rather than sleeping: the engine publishes on
    /// the main queue and SwiftUI commits its updates from the run loop.
    static func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// The view's layer tree drawn into a bitmap at `scale`. Going through
    /// the layers, not `cacheDisplay`, because SwiftUI's content lives in
    /// layers that are not views and `cacheDisplay` walks only views.
    @MainActor static func snapshot(_ view: NSView, dark: Bool) -> NSBitmapImageRep {
        let size = view.bounds.size
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        cg.setFillColor(dark
            ? CGColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1)
            : CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: size))
        // The hosting view is flipped — its layer's origin is top-left — while
        // the bitmap context is bottom-left. Mirror once, or the window comes
        // out upside down.
        if view.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        view.layer!.render(in: cg)
        return rep
    }

    static func write(_ rep: NSBitmapImageRep, to path: String) {
        let png = rep.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
    }
}
