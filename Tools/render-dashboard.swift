import AppKit
import SwiftUI

// Renders the dashboard for the README at 2×, on any display or none, by
// running the real engine against this machine and hosting the real
// DashboardView in an off-screen window, then reading its layer tree back.
//
// Compile with every app source except RexBoingApp.swift (the list
// Tools/check.sh uses for engine-check), then:
//
//   render-dashboard <outdir> [seconds]
//
// Samples for `seconds` (default 60) so the graphs have a trace to show, then
// writes dashboard.png — the panel exactly as it opens — and
// dashboard-lower.png — the same panel scrolled to its foot.
//
// Why not SwiftUI's ImageRenderer: it draws nothing for a ScrollView's
// content and a placeholder for AppKit-backed controls such as the segmented
// pickers, so the picture it makes is not the panel.
@main
enum RenderDashboard {
    static let width = Metrics.dashboardWidth
    static let scale: CGFloat = 2
    /// Stands in for the popover's dark material, which has no meaning off screen.
    static let ground = NSColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1)

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        let args = CommandLine.arguments
        let outDir = args.count > 1 ? args[1] : "docs"
        let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let engine = MetricsEngine()
        let preferences = Preferences.shared
        // What the popover does when it opens: full-rate process sampling and
        // an immediate tick, so the first frame is never a panel of zeros.
        engine.beginDashboardSampling()
        engine.refreshNow()

        let height = Metrics.dashboardHeight(on: NSScreen.main)
        let hosting = NSHostingView(
            rootView: DashboardView(height: height)
                .environmentObject(engine)
                .environmentObject(preferences))
        hosting.wantsLayer = true
        // Far outside every screen: the window has to exist for SwiftUI to
        // lay out and keep updating, but nobody should see it.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ground
        window.isOpaque = true
        window.contentView = hosting
        window.orderFrontRegardless()

        print("sampling for \(Int(seconds)) s…")
        pump(seconds)
        guard engine.hasReceivedFirstSample else {
            print("engine produced no sample"); exit(1)
        }

        write(snapshot(hosting), to: "\(outDir)/dashboard.png")

        guard let scroll = findScrollView(in: hosting), let document = scroll.documentView else {
            print("no scroll view found in the dashboard"); exit(1)
        }
        let overflow = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? overflow : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(1)
        write(snapshot(hosting), to: "\(outDir)/dashboard-lower.png")

        engine.endDashboardSampling()
        print("wrote \(outDir)/dashboard.png and \(outDir)/dashboard-lower.png: \(Int(width))×\(Int(height)) pt at \(Int(scale))×, scrolled \(Int(overflow)) pt for the lower one")
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

    static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
    }

    /// The view's layer tree drawn into a bitmap at `scale`. Going through
    /// the layers, not `cacheDisplay`, because SwiftUI's content lives in
    /// layers that are not views and `cacheDisplay` walks only views.
    @MainActor static func snapshot(_ view: NSView) -> NSBitmapImageRep {
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
        cg.setFillColor(ground.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        // The hosting view is flipped — its layer's origin is top-left — while
        // the bitmap context is bottom-left. Mirror once, or the panel comes
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
